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
        viewerLastReviewState: ReviewVerdict? = nil
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
            viewerLastReviewState: viewerLastReviewState
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
    /// `recentlyApprovedReviews`, and without this group it vanished outright.
    @Test
    func recentApprovalSurvivesInItsOwnGroup() throws {
        let state = AppState()
        state.recentlyApprovedReviews = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .approved
        )]
        let payload = ReviewsPayload.build(appState: state)
        #expect(group(try firstReview(payload)) == "approved_recently")
        #expect(groupCount(payload, "approved_recently") == 1)
    }

    /// …and drops off the far side of the window. In *no* group, not demoted to
    /// "not approved yet": nothing is asking the viewer for anything.
    @Test
    func approvalOlderThan24hIsInNoGroup() {
        let state = AppState()
        state.recentlyApprovedReviews = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-25 * 3600),
            viewerLastReviewState: .approved
        )]
        let payload = ReviewsPayload.build(appState: state)
        #expect(reviews(payload).isEmpty)
        #expect(groupCount(payload, "approved_recently") == 0)
    }

    /// The boundary is evaluated against an injected `now`, so the tail expires
    /// on the clock rather than on the next poll.
    @Test
    func windowBoundaryIsEvaluatedAtSerializationTime() {
        let approvedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let state = AppState()
        state.recentlyApprovedReviews = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: approvedAt,
            viewerLastReviewState: .approved
        )]
        let justInside = ReviewsPayload.build(appState: state, now: approvedAt.addingTimeInterval(23 * 3600))
        let justOutside = ReviewsPayload.build(appState: state, now: approvedAt.addingTimeInterval(24 * 3600 + 1))
        #expect(reviews(justInside).count == 1)
        #expect(reviews(justOutside).isEmpty)
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
        #expect(groupCount(payload, "approved_recently") == 0)
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

    /// The approved tail keeps its group — the fix must gate on queue
    /// membership, not simply stop honoring approvals.
    @Test
    func approvedTailStillGroupsAsApprovedRecently() throws {
        let state = AppState()
        state.recentlyApprovedReviews = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date().addingTimeInterval(-3600),
            viewerLastReviewState: .approved
        )]
        #expect(group(try firstReview(ReviewsPayload.build(appState: state))) == "approved_recently")
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

    /// The approved tail obeys the same repo/label filters as the queue — a repo
    /// you excluded shouldn't reappear once you approve something in it.
    @Test
    func approvedTailRespectsRepoFilters() {
        let state = AppState()
        state.excludeReviewRepos = ["foo/*"]
        state.recentlyApprovedReviews = [makeRequest(
            url: "https://github.com/foo/bar/pull/9",
            viewerLastReviewedAt: Date(),
            viewerLastReviewState: .approved
        )]
        #expect(reviews(ReviewsPayload.build(appState: state)).isEmpty)
    }
}
