import Foundation

/// Which section of the Reviews board a PR belongs to (CROW-982).
///
/// The board used to be one flat list fed by `review-requested:@me`, which meant
/// an approved PR **disappeared the instant you approved it** — GitHub clears
/// the pending review request on submit, so the PR left the only source the
/// board read. That is the #953 complaint in its sharpest form: work slipping
/// out of view with no way to answer "did I already do that one?" short of
/// opening GitHub.
///
/// Three groups, and a PR is in exactly one:
///
/// | Group | Rule |
/// |---|---|
/// | `inReview` | an active review session covers the PR |
/// | `notApprovedYet` | still in `review-requested:@me` — GitHub is asking you for something |
/// | `approvedRecently` | left the queue on your approval, within 24 h |
///
/// Precedence runs top to bottom, so a PR you approved a minute ago but which
/// has a live review session stays under **In review** — and one the author
/// re-requested after your approval reads as **Not approved yet**, because the
/// queue, not the last verdict, says whether the ball is in your court.
public enum ReviewGroup: String, Codable, Sendable, CaseIterable {
    case inReview = "in_review"
    case approvedRecently = "approved_recently"
    case notApprovedYet = "not_approved_yet"

    /// Display order — the order the board renders sections in, and the order
    /// precedence is evaluated in. Distinct from `allCases` (declaration order)
    /// so re-ordering the cases can't silently re-order the board.
    public static let displayOrder: [ReviewGroup] = [.inReview, .notApprovedYet, .approvedRecently]

    public var title: String {
        switch self {
        case .inReview: return "In review"
        case .notApprovedYet: return "Not approved yet"
        case .approvedRecently: return "Approved recently"
        }
    }
}

extension ReviewGroup {
    /// The window an approval stays visible for after it leaves the
    /// `review-requested:@me` queue. Matches `done_last_24h` on the tickets
    /// payload — same wording, same boundary, one notion of "recently" across
    /// both boards.
    public static let recentApprovalWindow: TimeInterval = 24 * 60 * 60

    /// Classify one review.
    ///
    /// `hasActiveReviewSession` is passed in rather than derived here because
    /// the answer lives in live `sessions`/`links`, which this model layer
    /// cannot see — and because it must be read at *serialization* time, not
    /// when the board was assembled (see `ReviewsPayload.build`).
    ///
    /// `now` is injected so the 24 h boundary is testable and so the cutoff is
    /// evaluated on each render rather than frozen at poll time — otherwise an
    /// approval could linger up to a poll past its window.
    ///
    /// `isRequestedOfViewer` — whether the PR is still in `review-requested:@me`
    /// — is what keeps actionable work out of the approved tail. Approving does
    /// not end the story: the author can push and re-request you, and GitHub
    /// puts the PR *back* in the queue with your verdict still reading
    /// `.approved`. Classifying on the verdict alone filed that under "Approved
    /// recently" for 24 h — work waiting on you, hidden under the heading that
    /// means "done" — and then flipped it to "Not approved yet" at hour 25,
    /// which is the same PR in two different groups depending only on the
    /// clock. Membership in the queue is the real signal, so it is checked
    /// first: anything GitHub is still asking you for is Not approved yet,
    /// whatever you decided last round.
    public static func classify(
        viewerLastReviewState: ReviewVerdict?,
        viewerLastReviewedAt: Date?,
        hasActiveReviewSession: Bool,
        isRequestedOfViewer: Bool,
        now: Date = Date()
    ) -> ReviewGroup {
        if hasActiveReviewSession { return .inReview }
        if isRequestedOfViewer { return .notApprovedYet }
        if viewerLastReviewState == .approved,
           let at = viewerLastReviewedAt,
           now.timeIntervalSince(at) < recentApprovalWindow {
            return .approvedRecently
        }
        // Unreachable from `ReviewsPayload` — the approved tail is pre-filtered
        // by `isRecentApproval`, so a non-requested PR reaching here is already
        // inside the window. Kept as the fallback anyway because it errs toward
        // *showing* the PR, and a review this board drops is the whole bug.
        return .notApprovedYet
    }

    /// Whether an approval is still inside the 24 h tail.
    ///
    /// Used to decide whether a PR from the `reviewed-by:@me` query — one that
    /// has already **left** the requested queue — should be shown at all. A PR
    /// that fails this is in no group, not in `notApprovedYet`: nothing is
    /// asking the viewer for anything, so surfacing it would be noise.
    public static func isRecentApproval(
        state: ReviewVerdict?,
        at: Date?,
        now: Date = Date()
    ) -> Bool {
        guard state == .approved, let at else { return false }
        return now.timeIntervalSince(at) < recentApprovalWindow
    }
}
