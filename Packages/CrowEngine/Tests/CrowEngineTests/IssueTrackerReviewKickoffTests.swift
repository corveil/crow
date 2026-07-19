import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Reviewer-side auto re-review decision (CROW-756). Covers the `shaAdvanced`
/// branch and stale-session teardown the headless migration (ADR 0008) dropped
/// when it ported `AppDelegate.onReviewRequestsRefreshed`.
@Suite("IssueTracker review kickoff decisions")
struct IssueTrackerReviewKickoffTests {

    private func makeSession(
        id: UUID = UUID(),
        lastReviewedHeadSha: String? = nil
    ) -> Session {
        Session(
            id: id,
            name: "review",
            status: .active,
            kind: .review,
            createdAt: Date(),
            updatedAt: Date(),
            lastReviewedHeadSha: lastReviewedHeadSha
        )
    }

    // No session, no existing-by-PR → create a fresh review session.
    @Test
    func noExistingSessionCreates() {
        let action = IssueTracker.reviewKickoffAction(
            reviewSessionID: nil,
            headRefOid: "sha-a",
            linkedSession: nil,
            existingByPRSessionID: nil
        )
        #expect(action == .create)
    }

    // Linked session whose last-reviewed head matches the PR head → nothing to
    // do. This is the regression guard: an unchanged head must NOT re-kick.
    @Test
    func linkedSessionAtSameHeadSkips() {
        let session = makeSession(lastReviewedHeadSha: "sha-a")
        let action = IssueTracker.reviewKickoffAction(
            reviewSessionID: session.id,
            headRefOid: "sha-a",
            linkedSession: session,
            existingByPRSessionID: session.id
        )
        #expect(action == .skip)
    }

    // Author pushed a new head after the reviewer's first pass → complete the
    // stale round-1 session and re-review the advanced head.
    @Test
    func advancedHeadReReviewsAndCarriesStaleID() {
        let session = makeSession(lastReviewedHeadSha: "sha-a")
        let action = IssueTracker.reviewKickoffAction(
            reviewSessionID: session.id,
            headRefOid: "sha-b",
            linkedSession: session,
            existingByPRSessionID: session.id
        )
        #expect(action == .reReview(staleSessionID: session.id))
    }

    // A round-1 session created before `lastReviewedHeadSha` existed (nil) must
    // still re-review once the head is known, rather than sit idle forever.
    @Test
    func nilLastReviewedHeadReReviews() {
        let session = makeSession(lastReviewedHeadSha: nil)
        let action = IssueTracker.reviewKickoffAction(
            reviewSessionID: session.id,
            headRefOid: "sha-b",
            linkedSession: session,
            existingByPRSessionID: session.id
        )
        #expect(action == .reReview(staleSessionID: session.id))
    }

    // Head SHA not yet fetched → never re-review on a missing head (would
    // otherwise thrash every session with a nil `headRefOid`).
    @Test
    func missingHeadDoesNotReReview() {
        let session = makeSession(lastReviewedHeadSha: "sha-a")
        let action = IssueTracker.reviewKickoffAction(
            reviewSessionID: session.id,
            headRefOid: nil,
            linkedSession: session,
            existingByPRSessionID: session.id
        )
        #expect(action == .skip)
    }

    // Clone window: the session + PR link exist (existingByPR resolves) but the
    // lagging `reviewSessionID` cross-ref hasn't been written back yet. Must not
    // double-kick a create.
    @Test
    func existingByPRWithoutReviewSessionIDSkips() {
        let session = makeSession(lastReviewedHeadSha: "sha-a")
        let action = IssueTracker.reviewKickoffAction(
            reviewSessionID: nil,
            headRefOid: "sha-a",
            linkedSession: nil,
            existingByPRSessionID: session.id
        )
        #expect(action == .skip)
    }
}
