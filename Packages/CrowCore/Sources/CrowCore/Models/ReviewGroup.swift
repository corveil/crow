import Foundation

/// Which section of the Reviews board a PR belongs to (CROW-982, CROW-990).
///
/// The board used to be one flat list fed by `review-requested:@me`, which meant
/// a PR **disappeared the instant you reviewed it** — GitHub clears the pending
/// review request on submit, so the PR left the only source the board read. That
/// is the #953 complaint in its sharpest form: work slipping out of view with no
/// way to answer "did I already do that one?" short of opening GitHub.
///
/// CROW-982 split the list in three and added a `reviewed-by:@me` search to
/// recover the tail. CROW-990 found the split still lost two whole populations,
/// because that second search was narrowed to **approvals on open PRs**:
///
///  - A PR you requested changes on (or merely commented on) matched nothing.
///    Not `review-requested:@me`, because submitting cleared the request; not
///    the approvals-only tail, because your verdict wasn't an approval. Eight
///    such PRs were live on one queue with zero of them anywhere in Crow.
///  - "Approved recently" was structurally near-empty. With the auto-merge
///    watcher on, an approved PR merges within minutes, and a merged PR is not
///    `state:open` — so the group built to answer "did I already do that one?"
///    showed zero while 22 PRs reviewed that day had merged.
///
/// Four groups, and a PR is in at most one:
///
/// | Group | Rule |
/// |---|---|
/// | `inReview` | an active review session covers the PR |
/// | `notApprovedYet` | still in `review-requested:@me` — GitHub is asking you for something |
/// | `waitingOnAuthor` | your last word was CHANGES_REQUESTED/COMMENTED and the PR is still open |
/// | `recentlyCompleted` | it left your queue in the last 24 h — merged, closed, or approved |
///
/// `notApprovedYet` and `waitingOnAuthor` hold the same *kind* of row and the
/// opposite next action — the first means the ball is in your court, the second
/// means it is with the author — which is exactly why they are two headings and
/// not one list sorted differently.
///
/// Precedence runs `inReview` → `recentlyCompleted` → the open-PR groups: a live
/// session beats any verdict state, and a PR that is no longer open cannot be
/// waiting on anyone. Among open PRs, queue membership still wins over the last
/// verdict, so a PR re-requested after your approval reads as `notApprovedYet`
/// rather than hiding under a heading that means done.
public enum ReviewGroup: String, Codable, Sendable, CaseIterable {
    case inReview = "in_review"
    case recentlyCompleted = "recently_completed"
    case notApprovedYet = "not_approved_yet"
    case waitingOnAuthor = "waiting_on_author"

    /// Display order — the order the board renders sections in. Distinct from
    /// `allCases` (declaration order) so re-ordering the cases can't silently
    /// re-order the board. Actionable work leads; finished work trails.
    public static let displayOrder: [ReviewGroup] = [
        .inReview, .notApprovedYet, .waitingOnAuthor, .recentlyCompleted,
    ]

    public var title: String {
        switch self {
        case .inReview: return "In review"
        case .notApprovedYet: return "Not approved yet"
        case .waitingOnAuthor: return "Waiting on author"
        case .recentlyCompleted: return "Recently completed"
        }
    }

    /// Whether a review entering this group can chime `reviewRequested`.
    ///
    /// Only groups that mean *someone asked you for something* qualify. The
    /// other two are populated by your own submitted verdict or by a PR
    /// finishing, and announcing work **leaving** the queue as work arriving is
    /// backwards — the reason CROW-982 kept the tail out of `detectReviewSounds`
    /// in the first place. Published on the payload so the web board reads this
    /// rule rather than re-listing group ids next to a `!==`.
    public var announcesAsNewRequest: Bool {
        switch self {
        case .inReview, .notApprovedYet: return true
        case .waitingOnAuthor, .recentlyCompleted: return false
        }
    }
}

extension ReviewGroup {
    /// How long a PR stays visible after it leaves the viewer's queue — merged,
    /// closed, or approved. Matches `done_last_24h` on the tickets payload —
    /// same wording, same boundary, one notion of "recently" across both boards.
    ///
    /// `waitingOnAuthor` deliberately has **no** window: those PRs never left
    /// anyone's queue, they are parked in the author's, and the oldest one in
    /// the queue that motivated CROW-990 was three weeks old. A 24 h cut there
    /// would re-hide precisely the rows the group exists to surface.
    public static let recentlyCompletedWindow: TimeInterval = 24 * 60 * 60

    /// Classify one review, or return `nil` for one the board should not show
    /// at all.
    ///
    /// Returning an Optional keeps membership and visibility as one rule. The
    /// alternative — a separate "should this be shown" predicate — is how the
    /// `reviewed-by:@me` rows got filtered to approvals in two different places
    /// in CROW-982, which is what hid the changes-requested population.
    /// `nil` never happens for a row still in the requested queue: GitHub is
    /// asking for something, so there is always a group for it.
    ///
    /// `hasActiveReviewSession` is passed in rather than derived here because
    /// the answer lives in live `sessions`/`links`, which this model layer
    /// cannot see — and because it must be read at *serialization* time, not
    /// when the board was assembled (see `ReviewsPayload.build`).
    ///
    /// `now` is injected so the 24 h boundary is testable and so the cutoff is
    /// evaluated on each render rather than frozen at poll time — otherwise a
    /// completed PR could linger up to a poll past its window.
    ///
    /// `isRequestedOfViewer` — whether the PR is still in `review-requested:@me`
    /// — is what keeps actionable work out of the finished tail. Reviewing does
    /// not end the story: the author can push and re-request you, and GitHub
    /// puts the PR *back* in the queue with your verdict still reading
    /// `.approved`. Classifying on the verdict alone filed that under the tail
    /// for 24 h — work waiting on you, hidden under the heading that means
    /// "done" — and then flipped it to "Not approved yet" at hour 25, which is
    /// the same PR in two different groups depending only on the clock.
    /// Membership in the queue is the real signal, so it is checked before any
    /// verdict: anything GitHub is still asking you for is Not approved yet,
    /// whatever you decided last round.
    ///
    /// The review is passed whole rather than field by field: the rule now
    /// reads five of its properties, and a call site that forgets one silently
    /// mis-files a PR instead of failing to compile.
    public static func classify(
        _ review: ReviewRequest,
        hasActiveReviewSession: Bool,
        isRequestedOfViewer: Bool,
        now: Date = Date()
    ) -> ReviewGroup? {
        if hasActiveReviewSession { return .inReview }
        // Before the queue check: a merged PR cannot be waiting on anyone, and
        // the requested search is `state:open` so the two can't both be true in
        // practice — this ordering just makes the ticket's stated precedence
        // ("Recently completed wins over the open-PR buckets for a PR that is
        // no longer open") true by construction rather than by luck.
        if review.isCompleted {
            // `requestedAt` (the PR's `updatedAt`) is the fallback because a
            // merged PR with no merge timestamp is a partial fetch, not a stale
            // one, and dropping it would re-hide the population this group
            // exists for. Both dates are then subject to the same window.
            return isWithinWindow(review.completedAt ?? review.requestedAt, now: now)
                ? .recentlyCompleted : nil
        }
        if isRequestedOfViewer { return .notApprovedYet }
        guard let verdict = review.viewerLastReviewState else {
            // No verdict and nothing asking: the viewer has no relationship to
            // this PR the board can describe. Unreachable from `ReviewsPayload`
            // — every non-requested row comes from `reviewed-by:@me`, which by
            // definition returns PRs the viewer reviewed.
            return nil
        }
        if verdict.isWaitingOnAuthor { return .waitingOnAuthor }
        if verdict == .approved {
            return isWithinWindow(review.viewerLastReviewedAt, now: now) ? .recentlyCompleted : nil
        }
        // `.dismissed` lands here. See `ReviewVerdict.isWaitingOnAuthor`: a
        // dismissed verdict leaves nothing owed in either direction, and the
        // re-request that follows one puts the PR back in the queue anyway.
        return nil
    }

    /// Whether a timestamp is inside the 24 h tail. A `nil` date is outside it —
    /// an undateable row would otherwise never expire.
    private static func isWithinWindow(_ at: Date?, now: Date) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) < recentlyCompletedWindow
    }
}
