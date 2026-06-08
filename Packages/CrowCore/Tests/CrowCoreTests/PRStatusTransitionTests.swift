import Foundation
import Testing
@testable import CrowCore

@Suite("PRStatus transitions")
struct PRStatusTransitionTests {
    private let sessionID = UUID()
    private let prURL = "https://github.com/foo/bar/pull/1"
    private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func status(
        review: PRStatus.ReviewStatus = .reviewRequired,
        checks: PRStatus.CheckStatus = .pending,
        sha: String? = nil,
        reviewID: String? = nil,
        failed: [String] = []
    ) -> PRStatus {
        PRStatus(
            checksPass: checks,
            reviewStatus: review,
            mergeable: .unknown,
            failedCheckNames: failed,
            headSha: sha,
            latestReviewID: reviewID
        )
    }

    private func compute(from old: PRStatus?, to new: PRStatus) -> [PRStatusTransition] {
        PRStatus.transitions(from: old, to: new, sessionID: sessionID, prURL: prURL, prNumber: 1)
    }

    // MARK: - First-observation gate

    @Test
    func firstObservationNeverFires() {
        // No prior status — even if the PR is already in a transition state,
        // we must not fire (it'd flood the user with notifications on every
        // app launch).
        #expect(compute(from: nil, to: status(review: .changesRequested)).isEmpty)
        #expect(compute(from: nil, to: status(checks: .failing, sha: shaA)).isEmpty)
        #expect(compute(from: nil, to: status(review: .changesRequested, checks: .failing, sha: shaA)).isEmpty)
    }

    // MARK: - Changes requested

    @Test
    func reviewRequiredToChangesRequestedFires() {
        let old = status(review: .reviewRequired)
        let new = status(review: .changesRequested)
        let ts = compute(from: old, to: new)
        #expect(ts.count == 1)
        #expect(ts.first?.kind == .changesRequested)
        #expect(ts.first?.sessionID == sessionID)
        #expect(ts.first?.prURL == prURL)
    }

    @Test
    func approvedToChangesRequestedFires() {
        let ts = compute(from: status(review: .approved), to: status(review: .changesRequested))
        #expect(ts.count == 1)
        #expect(ts.first?.kind == .changesRequested)
    }

    @Test
    func changesRequestedToChangesRequestedDoesNotFire() {
        // Status hasn't transitioned — every poll observes the same state with
        // the same review ID and SHA, so no re-fire.
        let old = status(review: .changesRequested, sha: shaA, reviewID: "R_1")
        let new = status(review: .changesRequested, sha: shaA, reviewID: "R_1")
        #expect(compute(from: old, to: new).isEmpty)
    }

    @Test
    func changesRequestedSameStateNewReviewIDFires() {
        // CROW-456: reviewer submitted a second "Request changes" without an
        // intervening approval. The review ID rotates, so we must re-arm.
        let old = status(review: .changesRequested, sha: shaA, reviewID: "R_1")
        let new = status(review: .changesRequested, sha: shaA, reviewID: "R_2")
        let ts = compute(from: old, to: new)
        #expect(ts.count == 1)
        #expect(ts.first?.kind == .changesRequested)
        #expect(ts.first?.latestReviewID == "R_2")
    }

    @Test
    func changesRequestedSameStateNewShaWithoutNewReviewDoesNotFire() {
        // CROW-456 review feedback: a head-SHA change alone must NOT fire.
        // GitHub doesn't dismiss CHANGES_REQUESTED on author push, so the
        // agent's own response push (after the auto-respond prompt told it
        // to commit + push + re-request reviewers) would otherwise trigger
        // auto-respond again — a self-sustaining loop. Real "round 2" always
        // brings a new formal review and a new review ID.
        let old = status(review: .changesRequested, sha: shaA, reviewID: "R_1")
        let new = status(review: .changesRequested, sha: shaB, reviewID: "R_1")
        #expect(compute(from: old, to: new).isEmpty)
    }

    @Test
    func changesRequestedNewReviewAfterAgentPushFires() {
        // The "agent pushed a fix, reviewer responded with more changes" path.
        // The fresh formal review rotates `latestReviewID` regardless of how
        // many SHAs the agent pushed in between, so `newReview` covers this
        // case without needing a separate post-commit-push trigger.
        let old = status(review: .changesRequested, sha: shaA, reviewID: "R_1")
        let new = status(review: .changesRequested, sha: shaB, reviewID: "R_2")
        let ts = compute(from: old, to: new)
        #expect(ts.count == 1)
        #expect(ts.first?.kind == .changesRequested)
        #expect(ts.first?.latestReviewID == "R_2")
        #expect(ts.first?.headSha == shaB)
    }

    @Test
    func changesRequestedToApprovedDoesNotFire() {
        // Reviewer approved — that's the rule clearing, not a new event to act on.
        let ts = compute(from: status(review: .changesRequested), to: status(review: .approved))
        #expect(ts.isEmpty)
    }

    // MARK: - Checks failing

    @Test
    func passingToFailingFires() {
        let old = status(checks: .passing, sha: shaA)
        let new = status(checks: .failing, sha: shaA, failed: ["lint"])
        let ts = compute(from: old, to: new)
        #expect(ts.count == 1)
        #expect(ts.first?.kind == .checksFailing)
        #expect(ts.first?.headSha == shaA)
        #expect(ts.first?.failedCheckNames == ["lint"])
    }

    @Test
    func pendingToFailingFires() {
        let ts = compute(from: status(checks: .pending, sha: shaA), to: status(checks: .failing, sha: shaA))
        #expect(ts.count == 1)
        #expect(ts.first?.kind == .checksFailing)
    }

    @Test
    func failingToFailingDoesNotFire() {
        // Pure transitions (no dedupe yet) treats this as no transition because
        // `old.checksPass == .failing` already.
        let ts = compute(from: status(checks: .failing, sha: shaA), to: status(checks: .failing, sha: shaA))
        #expect(ts.isEmpty)
    }

    @Test
    func failingToPassingDoesNotFire() {
        let ts = compute(from: status(checks: .failing, sha: shaA), to: status(checks: .passing, sha: shaA))
        #expect(ts.isEmpty)
    }

    // MARK: - Both transitions in one cycle

    @Test
    func simultaneousTransitionsFireBoth() {
        let old = status(review: .reviewRequired, checks: .pending, sha: shaA)
        let new = status(review: .changesRequested, checks: .failing, sha: shaA)
        let ts = compute(from: old, to: new)
        #expect(ts.count == 2)
        #expect(ts.contains(where: { $0.kind == .changesRequested }))
        #expect(ts.contains(where: { $0.kind == .checksFailing }))
    }

    // MARK: - Dedupe key

    @Test
    func dedupeKeyForChangesRequestedIncludesReviewIDOnly() {
        // CROW-456: review ID is the sole round-2 discriminator. Same review
        // collapses; new review breaks the key. Head SHA is intentionally NOT
        // in the key — see `changesRequestedSameStateNewShaWithoutNewReviewDoesNotFire`
        // for the rationale (avoids the agent-push self-loop).
        let base = PRStatusTransition(kind: .changesRequested, sessionID: sessionID, prURL: prURL, prNumber: 1, headSha: shaA, latestReviewID: "R_1")
        let sameAgain = PRStatusTransition(kind: .changesRequested, sessionID: sessionID, prURL: prURL, prNumber: 1, headSha: shaA, latestReviewID: "R_1")
        let newReview = PRStatusTransition(kind: .changesRequested, sessionID: sessionID, prURL: prURL, prNumber: 1, headSha: shaA, latestReviewID: "R_2")
        let onlyNewSha = PRStatusTransition(kind: .changesRequested, sessionID: sessionID, prURL: prURL, prNumber: 1, headSha: shaB, latestReviewID: "R_1")

        #expect(base.dedupeKey == sameAgain.dedupeKey)
        #expect(base.dedupeKey != newReview.dedupeKey)
        #expect(base.dedupeKey == onlyNewSha.dedupeKey)
    }

    @Test
    func dedupeKeyForChecksFailingIncludesSha() {
        // A new commit that also fails CI must be allowed to re-fire.
        let t1 = PRStatusTransition(kind: .checksFailing, sessionID: sessionID, prURL: prURL, prNumber: 1, headSha: shaA)
        let t2 = PRStatusTransition(kind: .checksFailing, sessionID: sessionID, prURL: prURL, prNumber: 1, headSha: shaB)
        #expect(t1.dedupeKey != t2.dedupeKey)
    }
}
