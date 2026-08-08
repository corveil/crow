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
        reviewSessionID: UUID? = nil
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
            headRefOid: headRefOid
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
}
