import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import CrowEngine

/// Verifies the policy gate added for #311: review sessions must never
/// trigger auto-respond automation, regardless of the global
/// `respondToChangesRequested` / `respondToFailedChecks` toggles. Work
/// sessions continue to flow through unaffected.
@Suite("AutoRespondCoordinator review-session gate")
@MainActor
struct AutoRespondCoordinatorReviewSessionTests {

    private func makeCoordinator(sessions: [Session]) -> AutoRespondCoordinator {
        let state = AppState()
        state.sessions = sessions
        return AutoRespondCoordinator(
            appState: state,
            providerManager: ProviderManager(),
            settingsProvider: { AutoRespondSettings(respondToChangesRequested: true, respondToFailedChecks: true) }
        )
    }

    @Test func skipsReviewSessionOnChangesRequested() {
        let review = Session(name: "review-crow-123", kind: .review)
        let coord = makeCoordinator(sessions: [review])
        let t = PRStatusTransition(
            kind: .changesRequested,
            sessionID: review.id,
            prURL: "https://github.com/radiusmethod/crow/pull/123",
            prNumber: 123
        )
        #expect(coord.shouldSkipReviewSession(t))
    }

    @Test func skipsReviewSessionOnChecksFailing() {
        let review = Session(name: "review-crow-456", kind: .review)
        let coord = makeCoordinator(sessions: [review])
        let t = PRStatusTransition(
            kind: .checksFailing,
            sessionID: review.id,
            prURL: "https://github.com/radiusmethod/crow/pull/456",
            prNumber: 456
        )
        #expect(coord.shouldSkipReviewSession(t))
    }

    @Test func doesNotSkipWorkSession() {
        let work = Session(name: "feature-crow-789", kind: .work)
        let coord = makeCoordinator(sessions: [work])
        let t = PRStatusTransition(
            kind: .changesRequested,
            sessionID: work.id,
            prURL: "https://github.com/radiusmethod/crow/pull/789",
            prNumber: 789
        )
        #expect(!coord.shouldSkipReviewSession(t))
    }

    /// If the transition references a session ID that's no longer in
    /// `appState.sessions` (race with delete, stale poll), the gate should
    /// not pretend it was a review — fall through to the normal toggle path.
    @Test func unknownSessionIsNotTreatedAsReview() {
        let coord = makeCoordinator(sessions: [])
        let t = PRStatusTransition(
            kind: .changesRequested,
            sessionID: UUID(),
            prURL: "https://github.com/radiusmethod/crow/pull/1",
            prNumber: 1
        )
        #expect(!coord.shouldSkipReviewSession(t))
    }
}
