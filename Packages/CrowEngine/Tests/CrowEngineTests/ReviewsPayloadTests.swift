import Foundation
import Testing
import CrowCore
import CrowIPC
import CrowProvider
@testable import CrowEngine

/// The `list-reviews` payload (CROW-945).
///
/// Two things are under test here. First, that `kickoff_action` reports what
/// `SessionService.createReviewSession` would actually do — the board used to
/// gate its button on "does a non-completed session link to this PR", which is
/// a much weaker question than "has this review round been answered", so a
/// re-requested PR rendered only "Go to Session" pointing at a dead round.
/// Second, that both routers answer from this one builder: `RPCHandlers` (the
/// socket, i.e. `crow list-reviews`) and `EngineRouter` (the web `/rpc`) each
/// carried a byte-identical copy before, so the CLI and the browser agreed only
/// by accident of copy-paste.
@Suite("list-reviews payload")
@MainActor
struct ReviewsPayloadTests {

    private func makeRequest(
        url: String,
        headRefOid: String? = nil,
        reviewSessionID: UUID? = nil,
        viewerLastReviewedAt: Date? = nil,
        viewerLastReviewState: ReviewVerdict? = nil,
        viewerLastReviewedHeadSha: String? = nil,
        state: String? = nil,
        completedAt: Date? = nil
    ) -> ReviewRequest {
        ReviewRequest(
            id: "github:foo/bar#9",
            prNumber: 9,
            title: "Review me",
            url: url,
            repo: "foo/bar",
            author: "alice",
            headBranch: "feature",
            baseBranch: "main",
            reviewSessionID: reviewSessionID,
            headRefOid: headRefOid,
            viewerLastReviewedAt: viewerLastReviewedAt,
            viewerLastReviewState: viewerLastReviewState,
            viewerLastReviewedHeadSha: viewerLastReviewedHeadSha,
            state: state,
            completedAt: completedAt
        )
    }

    private func makeState(
        request: ReviewRequest,
        session: Session? = nil
    ) -> AppState {
        let state = AppState()
        state.reviewRequests = [request]
        if let session {
            state.sessions = [session]
            state.links[session.id] = [
                SessionLink(sessionID: session.id, label: "PR", url: request.url, linkType: .pr)
            ]
        }
        return state
    }

    private func firstReview(_ payload: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case let .array(reviews)? = payload["reviews"],
              case let .object(first)? = reviews.first else {
            throw TestFailure.missingReview
        }
        return first
    }

    private enum TestFailure: Error { case missingReview }

    private func action(_ review: [String: JSONValue]) -> String? {
        guard case let .string(s)? = review["kickoff_action"] else { return nil }
        return s
    }

    @Test
    func unclaimedReviewOffersCreate() throws {
        let request = makeRequest(url: "https://github.com/foo/bar/pull/9", headRefOid: "sha-a")
        let payload = ReviewsPayload.build(appState: makeState(request: request))
        #expect(action(try firstReview(payload)) == "create")
    }

    @Test
    func liveRoundAtTheSameHeadSkips() throws {
        let session = Session(
            name: "review", kind: .review,
            lastReviewedHeadSha: "sha-a"
        )
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-a",
            reviewSessionID: session.id
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request, session: session))
        #expect(action(try firstReview(payload)) == "skip")
    }

    /// THE CROW-945 board symptom. Round 1's session is still linked and the
    /// author has pushed + re-requested, so the head has moved past what that
    /// session reviewed. The board must offer the next round rather than only
    /// "Go to Session" — which was the state with no way forward short of
    /// deleting the session by hand.
    @Test
    func advancedHeadOffersReReview() throws {
        let session = Session(
            name: "review", kind: .review,
            lastReviewedHeadSha: "sha-a"
        )
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-b",
            reviewSessionID: session.id
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request, session: session))
        #expect(action(try firstReview(payload)) == "re_review")
    }

    /// A completed round stops shadowing the PR: `existingReviewSession`
    /// excludes completed/archived, so the next request reads as a fresh one.
    /// This is what rule 1 buys once it can actually fire.
    @Test
    func completedRoundNoLongerShadowsThePR() throws {
        var session = Session(
            name: "review", kind: .review,
            lastReviewedHeadSha: "sha-a"
        )
        session.status = .completed
        // `reviewSessionID` is nil because `IssueTracker` only cross-references
        // against `reviewSessions`, which excludes completed ones.
        let request = makeRequest(url: "https://github.com/foo/bar/pull/9", headRefOid: "sha-a")
        let payload = ReviewsPayload.build(appState: makeState(request: request, session: session))
        #expect(action(try firstReview(payload)) == "create")
    }

    /// The cross-reference lags the actual session by up to a poll, so the
    /// action must also consult the authoritative link-based lookup — otherwise
    /// the ~10s clone window reads as "nothing covers this PR" and double-kicks
    /// (CROW-406). Note the session carries the head it was created against:
    /// `createReviewSession` stamps `lastReviewedHeadSha` from the PR metadata
    /// it fetched, so a just-created round is never mistaken for a stale one.
    @Test
    func inFlightKickoffIsSkippedBeforeCrossRefLands() throws {
        let session = Session(name: "review", kind: .review, lastReviewedHeadSha: "sha-a")
        // `reviewSessionID` nil — IssueTracker hasn't re-polled yet.
        let request = makeRequest(url: "https://github.com/foo/bar/pull/9", headRefOid: "sha-a")
        let payload = ReviewsPayload.build(appState: makeState(request: request, session: session))
        #expect(action(try firstReview(payload)) == "skip")
    }

    /// A linked session with no recorded head reads as re-reviewable. That's
    /// `reviewKickoffAction`'s long-standing rule (an unknown head can't be
    /// shown to cover the current one) and it now reaches the board and the
    /// manual path, not just the `autoReviewRepos` watcher — so pin it. In
    /// practice this is only legacy sessions predating CROW-290; nothing
    /// auto-fires from it, since the board needs a click and the auto path
    /// needs `autoReviewRepos`.
    @Test
    func linkedSessionWithNoRecordedHeadOffersReReview() throws {
        let session = Session(name: "review", kind: .review, lastReviewedHeadSha: nil)
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-a",
            reviewSessionID: session.id
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request, session: session))
        #expect(action(try firstReview(payload)) == "re_review")
    }

    /// No head from the provider → never re-review on a guess. `shaAdvanced`
    /// requires a known head, so an unfetched one leaves the round alone.
    @Test
    func unknownHeadNeverReReviews() throws {
        let session = Session(name: "review", kind: .review, lastReviewedHeadSha: "sha-a")
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: nil,
            reviewSessionID: session.id
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request, session: session))
        #expect(action(try firstReview(payload)) == "skip")
    }

    /// `requested_at` was permanently nil in production (the fractional-seconds
    /// formatter), which blanked the board's relative-time chip and collapsed
    /// its "newest first" sort to `.distantPast` for every row.
    @Test
    func requestedAtAndHeadAreSerialized() throws {
        var request = makeRequest(url: "https://github.com/foo/bar/pull/9", headRefOid: "sha-a")
        request.requestedAt = Date(timeIntervalSince1970: 1780740000)
        let review = try firstReview(ReviewsPayload.build(appState: makeState(request: request)))
        guard case let .string(stamp)? = review["requested_at"] else {
            Issue.record("requested_at missing"); return
        }
        #expect(stamp.hasPrefix("2026-06-06T10:00:00"))
        #expect(review["head_ref_oid"] == .string("sha-a"))
    }

    /// Total switch over the enum — a new case must fail the build here rather
    /// than serialize as something the board silently doesn't handle.
    @Test
    func actionNamesAreStable() {
        #expect(ReviewsPayload.actionName(.create) == "create")
        #expect(ReviewsPayload.actionName(.skip) == "skip")
        #expect(ReviewsPayload.actionName(.reReview(staleSessionID: UUID())) == "re_review")
    }

    // MARK: - Grouping (CROW-982)

    private func group(_ review: [String: JSONValue]) -> String? {
        guard case let .string(s)? = review["group"] else { return nil }
        return s
    }

    private func reviews(_ payload: [String: JSONValue]) -> [[String: JSONValue]] {
        guard case let .array(items)? = payload["reviews"] else { return [] }
        return items.compactMap { if case let .object(o) = $0 { return o } else { return nil } }
    }

    private func groupCount(_ payload: [String: JSONValue], _ name: String) -> Int? {
        guard case let .object(counts)? = payload["group_counts"],
              case let .int(n)? = counts[name] else { return nil }
        return n
    }

    /// The baseline: requested of me, nothing submitted yet.
    @Test
    func neverReviewedIsNotApprovedYet() throws {
        let request = makeRequest(url: "https://github.com/foo/bar/pull/9", headRefOid: "sha-a")
        let payload = ReviewsPayload.build(appState: makeState(request: request))
        #expect(group(try firstReview(payload)) == "not_approved_yet")
    }

    /// Requesting changes must not move the PR anywhere — the ball is still in
    /// the reviewer's court, and the timestamp alone (which is all the model
    /// carried before CROW-982) cannot tell this from an approval.
    @Test
    func changesRequestedStaysNotApprovedYet() throws {
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-a",
            viewerLastReviewedAt: Date(),
            viewerLastReviewState: .changesRequested
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request))
        #expect(group(try firstReview(payload)) == "not_approved_yet")
    }

    /// An active review session wins over everything else — including a fresh
    /// approval, which is the one case where two groups could both claim the PR.
    @Test
    func activeSessionWinsOverFreshApproval() throws {
        let session = Session(name: "review", kind: .review, lastReviewedHeadSha: "sha-a")
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-a",
            reviewSessionID: session.id,
            viewerLastReviewedAt: Date(),
            viewerLastReviewState: .approved
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request, session: session))
        #expect(group(try firstReview(payload)) == "in_review")
    }

    /// THE CROW-982 symptom. Approving clears GitHub's pending request, so the
    /// PR leaves `review-requested:@me` entirely — it survives only in
    /// `reviewedPRs`, and without this group it vanished outright.
    @Test
    func recentApprovalSurvivesInItsOwnGroup() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .approved
        )]
        let payload = ReviewsPayload.build(appState: state)
        #expect(group(try firstReview(payload)) == "recently_completed")
        #expect(groupCount(payload, "recently_completed") == 1)
    }

    /// …and drops off the far side of the window. In *no* group, not demoted to
    /// "not approved yet": nothing is asking the viewer for anything.
    @Test
    func approvalOlderThan24hIsInNoGroup() {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-25 * 3600),
            viewerLastReviewState: .approved
        )]
        let payload = ReviewsPayload.build(appState: state)
        #expect(reviews(payload).isEmpty)
        #expect(groupCount(payload, "recently_completed") == 0)
    }

    /// The boundary is evaluated against an injected `now`, so the tail expires
    /// on the clock rather than on the next poll.
    @Test
    func windowBoundaryIsEvaluatedAtSerializationTime() {
        let approvedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: approvedAt,
            viewerLastReviewState: .approved
        )]
        let justInside = ReviewsPayload.build(appState: state, now: approvedAt.addingTimeInterval(23 * 3600))
        let justOutside = ReviewsPayload.build(appState: state, now: approvedAt.addingTimeInterval(24 * 3600 + 1))
        #expect(reviews(justInside).count == 1)
        #expect(reviews(justOutside).isEmpty)
    }

    // MARK: - CROW-990: Waiting on author

    /// THE CROW-990 GAP 1 SYMPTOM, and the exact shape of corveil/corveil#2141:
    /// open, changes requested on 08-10, `reviewRequests: []`. It matched
    /// nothing — GitHub had cleared the pending request on submit, and the
    /// `reviewed-by:@me` tail was narrowed to approvals. Eight such PRs were
    /// live on one queue and none of them appeared anywhere in Crow.
    @Test
    func changesRequestedOnAnOpenPRWaitsOnTheAuthor() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/2141",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .changesRequested,
            state: "OPEN"
        )]
        let payload = ReviewsPayload.build(appState: state)
        #expect(group(try firstReview(payload)) == "waiting_on_author")
        #expect(groupCount(payload, "waiting_on_author") == 1)
    }

    /// A `--comment` review counts too. It closes no review round (CROW-945
    /// still excludes COMMENTED from `roundClosingReviewStates`) but it is
    /// unambiguously "I have said my piece" — three of the eight lost PRs were
    /// exactly this.
    @Test
    func commentedOnAnOpenPRWaitsOnTheAuthor() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/2136",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .commented,
            state: "OPEN"
        )]
        #expect(group(try firstReview(ReviewsPayload.build(appState: state))) == "waiting_on_author")
    }

    /// Waiting on author has **no** 24 h window — the oldest row in the queue
    /// that motivated the ticket was three weeks old, and a tail cut here would
    /// re-hide precisely what the group exists to surface.
    @Test
    func waitingOnAuthorDoesNotExpire() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/1748",
            viewerLastReviewedAt: Date().addingTimeInterval(-26 * 24 * 3600),
            viewerLastReviewState: .changesRequested,
            state: "OPEN"
        )]
        #expect(group(try firstReview(ReviewsPayload.build(appState: state))) == "waiting_on_author")
    }

    /// Re-requesting flips it back: the queue, not the last verdict, says whose
    /// court the ball is in. Same rule that keeps a re-requested approval out of
    /// the completed tail.
    @Test
    func reRequestAfterChangesRequestedReturnsToTheQueue() throws {
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .changesRequested,
            state: "OPEN"
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request))
        #expect(group(try firstReview(payload)) == "not_approved_yet")
        #expect(groupCount(payload, "waiting_on_author") == 0)
    }

    /// A dismissed verdict leaves nothing owed in either direction — it is not
    /// the author's move, and GitHub re-requests the reviewer when it wants
    /// another look. Shown in no group rather than parked under a heading that
    /// claims someone is being waited on.
    @Test
    func dismissedVerdictIsInNoGroup() {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .dismissed,
            state: "OPEN"
        )]
        #expect(reviews(ReviewsPayload.build(appState: state)).isEmpty)
    }

    // MARK: - CROW-997: Waiting on author is not a kickoff queue

    /// THE CROW-997 SYMPTOM. The ball is with the author, so the card must not
    /// lead with Start Review — and because `.skip` is also what the board reads
    /// to decide selectability, the row drops out of batch "Start Review (N)" by
    /// the same token. Before this, every such row fell through to `.create`:
    /// the round auto-completed when the verdict landed, so there was no
    /// `linkedSession` for `shaAdvanced` to compare against and nothing to stop
    /// the create branch.
    @Test
    func waitingOnAuthorAtTheReviewedHeadSkips() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/2141",
            headRefOid: "sha-a",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .changesRequested,
            viewerLastReviewedHeadSha: "sha-a",
            state: "OPEN"
        )]
        let payload = ReviewsPayload.build(appState: state)
        let review = try firstReview(payload)
        #expect(group(review) == "waiting_on_author")
        #expect(action(review) == "skip")
    }

    /// The case a blanket suppression would break, and the reason the rule is
    /// conditional. The author pushed **without** re-requesting: GitHub never
    /// puts the PR back in `review-requested:@me`, so it stays under this
    /// heading — but there genuinely is something new to look at, and the board
    /// is the only way to reach it for anyone running with CROW-921's
    /// auto-re-request watcher off.
    @Test
    func waitingOnAuthorOffersCreateOnceTheHeadMoves() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/2141",
            headRefOid: "sha-b",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .changesRequested,
            viewerLastReviewedHeadSha: "sha-a",
            state: "OPEN"
        )]
        let review = try firstReview(ReviewsPayload.build(appState: state))
        #expect(group(review) == "waiting_on_author")
        // `.create`, not `.reReview`: the previous round was completed the moment
        // the verdict landed, so there is no stale session to retire.
        #expect(action(review) == "create")
    }

    /// An unfetched SHA on either side must keep the button. Suppressing claims
    /// "there is nothing new here" and takes the row's only way forward off the
    /// card, so a partial fetch must not be allowed to make that claim — the same
    /// "absence is not evidence" rule the verdict and state fields follow.
    @Test(arguments: [("sha-a", nil), (nil, "sha-a"), (nil, nil)] as [(String?, String?)])
    func waitingOnAuthorWithAnUnknownHeadKeepsItsButton(head: String?, reviewed: String?) throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/2141",
            headRefOid: head,
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .changesRequested,
            viewerLastReviewedHeadSha: reviewed,
            state: "OPEN"
        )]
        let review = try firstReview(ReviewsPayload.build(appState: state))
        #expect(group(review) == "waiting_on_author")
        #expect(action(review) == "create")
    }

    /// The suppression is scoped to the one group that means it. A PR still in
    /// the requested queue is asking you for something no matter what you said
    /// last round, so matching heads must not silence it — that would hide
    /// exactly the row GitHub is chasing you about.
    @Test
    func matchingHeadsDoNotSuppressAQueuedReview() throws {
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-a",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .changesRequested,
            viewerLastReviewedHeadSha: "sha-a"
        )
        let review = try firstReview(ReviewsPayload.build(appState: makeState(request: request)))
        #expect(group(review) == "not_approved_yet")
        #expect(action(review) == "create")
    }

    /// The head the verdict was submitted against rides the payload beside the
    /// PR's current head, so `crow list-reviews` shows the comparison the
    /// suppression turns on rather than an unexplained `skip`.
    @Test
    func reviewedHeadIsSerialized() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/2141",
            headRefOid: "sha-b",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .changesRequested,
            viewerLastReviewedHeadSha: "sha-a",
            state: "OPEN"
        )]
        let review = try firstReview(ReviewsPayload.build(appState: state))
        #expect(review["viewer_last_reviewed_head_sha"] == .string("sha-a"))
        #expect(review["head_ref_oid"] == .string("sha-b"))
    }

    // MARK: - CROW-990: Recently completed    /// THE CROW-990 GAP 2 SYMPTOM. With the auto-merge watcher on, an approved
    /// PR merges within minutes — and a merged PR is not `state:open`, so the
    /// group built to answer "did I already do that one?" read zero while 22
    /// PRs reviewed that day had merged.
    @Test
    func mergedPRAppearsUnderRecentlyCompleted() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-4 * 3600),
            viewerLastReviewState: .approved,
            state: "MERGED",
            completedAt: Date().addingTimeInterval(-3 * 3600)
        )]
        let payload = ReviewsPayload.build(appState: state)
        #expect(group(try firstReview(payload)) == "recently_completed")
    }

    /// The case the ticket calls out by name: you requested changes, the author
    /// fixed it, and **someone else** approved and merged. Your verdict is still
    /// CHANGES_REQUESTED, but the PR is over — it belongs under completed, not
    /// under a heading that says an author owes you something.
    @Test
    func mergedByAnotherReviewerStillCountsAsCompleted() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-6 * 3600),
            viewerLastReviewState: .changesRequested,
            state: "MERGED",
            completedAt: Date().addingTimeInterval(-1 * 3600)
        )]
        let payload = ReviewsPayload.build(appState: state)
        #expect(group(try firstReview(payload)) == "recently_completed")
        #expect(groupCount(payload, "waiting_on_author") == 0)
    }

    /// A PR closed without merging is equally over.
    @Test
    func closedUnmergedPRAlsoCountsAsCompleted() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-6 * 3600),
            viewerLastReviewState: .changesRequested,
            state: "CLOSED",
            completedAt: Date().addingTimeInterval(-2 * 3600)
        )]
        #expect(group(try firstReview(ReviewsPayload.build(appState: state))) == "recently_completed")
    }

    /// The completed window measures from the merge, not from the review. A PR
    /// you reviewed a week ago and that merged an hour ago is *recent*.
    @Test
    func completedWindowMeasuresFromTheMergeNotTheReview() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-7 * 24 * 3600),
            viewerLastReviewState: .approved,
            state: "MERGED",
            completedAt: Date().addingTimeInterval(-3600)
        )]
        #expect(group(try firstReview(ReviewsPayload.build(appState: state))) == "recently_completed")
    }

    /// …and it does expire, unlike Waiting on author.
    @Test
    func mergeOlderThan24hIsInNoGroup() {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewState: .approved,
            state: "MERGED",
            completedAt: Date().addingTimeInterval(-25 * 3600)
        )]
        #expect(reviews(ReviewsPayload.build(appState: state)).isEmpty)
    }

    /// Precedence: In review > Recently completed > the open-PR groups. A live
    /// session survives the PR merging under it — the session is what the user
    /// is looking at, and `autoCompleteFinishedReviews` closes it on its own
    /// schedule.
    @Test
    func activeSessionWinsOverAMergedPR() throws {
        let session = Session(name: "review", kind: .review, lastReviewedHeadSha: "sha-a")
        let state = AppState()
        var request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-a",
            reviewSessionID: session.id,
            viewerLastReviewState: .approved,
            state: "MERGED",
            completedAt: Date()
        )
        request.reviewSessionID = session.id
        state.reviewedPRs = [request]
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR", url: request.url, linkType: .pr)
        ]
        #expect(group(try firstReview(ReviewsPayload.build(appState: state))) == "in_review")
    }

    /// A shipped PR cannot be reviewed again, so the board must not offer to.
    /// `reviewKickoffAction` reasons about heads and sessions and knows nothing
    /// about the PR being over — it would happily return `create` here, which
    /// also makes the row selectable in batch-start mode.
    @Test
    func completedPRIsNotOfferedForReview() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-a",
            viewerLastReviewState: .approved,
            state: "MERGED",
            completedAt: Date().addingTimeInterval(-3600)
        )]
        #expect(action(try firstReview(ReviewsPayload.build(appState: state))) == "skip")
    }

    /// The lifecycle fields have to reach the wire — the card labels its
    /// timestamp "merged"/"closed"/"approved" off exactly these.
    @Test
    func lifecycleFieldsAreSerialized() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewState: .approved,
            state: "MERGED",
            completedAt: Date(timeIntervalSince1970: 1780740000)
        )]
        let review = try firstReview(ReviewsPayload.build(
            appState: state, now: Date(timeIntervalSince1970: 1780740000)
        ))
        #expect(review["state"] == .string("MERGED"))
        guard case let .string(stamp)? = review["completed_at"] else {
            Issue.record("completed_at missing"); return
        }
        #expect(stamp.hasPrefix("2026-06-06T10:00:00"))
    }

    /// Which groups may chime is published rather than re-derived on the client
    /// — naming the excluded group inline is what would let a newly added group
    /// opt itself into `reviewRequested` by default.
    @Test
    func chimeEligibilityIsPublishedPerGroup() {
        let payload = ReviewsPayload.build(appState: AppState())
        guard case let .object(map)? = payload["group_announces_new_request"] else {
            Issue.record("group_announces_new_request missing"); return
        }
        #expect(map["not_approved_yet"] == .bool(true))
        #expect(map["in_review"] == .bool(true))
        #expect(map["waiting_on_author"] == .bool(false))
        #expect(map["recently_completed"] == .bool(false))
    }

    /// Every group is counted even at zero, so the board can render a section
    /// that says *what* is empty instead of dropping it (#953).
    @Test
    func emptyGroupsStillCarryAZeroCount() {
        let payload = ReviewsPayload.build(appState: AppState())
        for g in ReviewGroup.displayOrder {
            #expect(groupCount(payload, g.rawValue) == 0)
        }
        guard case let .array(order)? = payload["group_order"] else {
            Issue.record("group_order missing"); return
        }
        #expect(order == ReviewGroup.displayOrder.map { .string($0.rawValue) })
    }

    /// The verdict has to reach the wire — without it the board cannot tell
    /// "not approved yet" from "I approved this", which is the whole split.
    @Test
    func verdictAndTimestampAreSerialized() throws {
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date(timeIntervalSince1970: 1780740000),
            viewerLastReviewState: .changesRequested
        )
        let review = try firstReview(ReviewsPayload.build(appState: makeState(request: request)))
        #expect(review["viewer_last_review_state"] == .string("CHANGES_REQUESTED"))
        guard case let .string(stamp)? = review["viewer_last_reviewed_at"] else {
            Issue.record("viewer_last_reviewed_at missing"); return
        }
        #expect(stamp.hasPrefix("2026-06-06T10:00:00"))
    }

    /// THE PR #984 REVIEW FINDING. Approving doesn't end the story: the author
    /// can push and re-request, and GitHub returns the PR to
    /// `review-requested:@me` with the viewer's verdict still reading APPROVED.
    /// Classifying on the verdict alone filed that under "Approved recently" —
    /// work waiting on you, hidden under the heading that means done.
    @Test
    func reRequestedAfterApprovalIsNotApprovedYet() throws {
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            headRefOid: "sha-b",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .approved
        )
        let payload = ReviewsPayload.build(appState: makeState(request: request))
        #expect(group(try firstReview(payload)) == "not_approved_yet")
        #expect(groupCount(payload, "recently_completed") == 0)
    }

    /// …and the same PR must not change groups purely because the clock moved
    /// past 24 h. Before the fix it read `approved_recently` at hour 1 and
    /// `not_approved_yet` at hour 25 — one PR, two groups, same facts.
    @Test
    func reRequestedAfterApprovalIsStableAcrossTheWindowBoundary() throws {
        let approvedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let request = makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: approvedAt,
            viewerLastReviewState: .approved
        )
        let state = makeState(request: request)
        let inside = ReviewsPayload.build(appState: state, now: approvedAt.addingTimeInterval(3600))
        let outside = ReviewsPayload.build(appState: state, now: approvedAt.addingTimeInterval(25 * 3600))
        #expect(group(try firstReview(inside)) == "not_approved_yet")
        #expect(group(try firstReview(outside)) == "not_approved_yet")
    }

    /// The completed tail keeps its group — the fix must gate on queue
    /// membership, not simply stop honoring approvals.
    @Test
    func approvedTailStillGroupsAsRecentlyCompleted() throws {
        let state = AppState()
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .approved
        )]
        #expect(group(try firstReview(ReviewsPayload.build(appState: state))) == "recently_completed")
    }

    /// #953 direction C: filters that hide live requests must say so, or an
    /// empty board reads as "GitHub is asking nothing of me".
    @Test
    func hiddenByFiltersIsReported() {
        let state = AppState()
        state.hiddenReviewCount = 12
        let payload = ReviewsPayload.build(appState: state)
        #expect(payload["hidden_by_filters"] == .int(12))
    }

    /// The reviewed-by lists obey the same repo/label filters as the queue — a
    /// repo you excluded shouldn't reappear once you review something in it.
    @Test
    func reviewedTailRespectsRepoFilters() {
        let state = AppState()
        state.excludeReviewRepos = ["foo/*"]
        state.reviewedPRs = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date(),
            viewerLastReviewState: .approved
        )]
        #expect(reviews(ReviewsPayload.build(appState: state)).isEmpty)
    }
}
