import Foundation
import Testing
@testable import CrowCore

@Suite("PRStatus transitions (checks-failing edge)")
struct PRStatusTransitionTests {
    private let sessionID = UUID()
    private let prURL = "https://github.com/foo/bar/pull/1"
    private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func status(
        review: PRStatus.ReviewStatus = .reviewRequired,
        checks: PRStatus.CheckStatus = .pending,
        sha: String? = nil,
        failed: [String] = []
    ) -> PRStatus {
        PRStatus(
            checksPass: checks,
            reviewStatus: review,
            mergeable: .unknown,
            failedCheckNames: failed,
            headSha: sha
        )
    }

    private func compute(from old: PRStatus?, to new: PRStatus) -> [PRStatusTransition] {
        PRStatus.transitions(from: old, to: new, sessionID: sessionID, prURL: prURL, prNumber: 1)
    }

    // MARK: - First-observation gate

    @Test
    func firstObservationOpenWithNoFailingChecksDoesNotFire() {
        // Post-CROW-508: only `.checksFailing` is edge-emitted; everything
        // about `.changesRequested` moved to the stateless `needsRefine`
        // path in `IssueTracker`.
        #expect(compute(from: nil, to: status(review: .reviewRequired, checks: .pending)).isEmpty)
        #expect(compute(from: nil, to: status(review: .approved, checks: .passing)).isEmpty)
        #expect(compute(from: nil, to: status(review: .changesRequested)).isEmpty)
    }

    @Test
    func firstObservationFailingChecksFires() {
        let ts = compute(from: nil, to: status(checks: .failing, sha: shaA, failed: ["lint"]))
        #expect(ts.count == 1)
        #expect(ts.first?.kind == .checksFailing)
        #expect(ts.first?.headSha == shaA)
        #expect(ts.first?.failedCheckNames == ["lint"])
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
        let ts = compute(from: status(checks: .failing, sha: shaA), to: status(checks: .failing, sha: shaA))
        #expect(ts.isEmpty)
    }

    @Test
    func failingToPassingDoesNotFire() {
        let ts = compute(from: status(checks: .failing, sha: shaA), to: status(checks: .passing, sha: shaA))
        #expect(ts.isEmpty)
    }

    // MARK: - changes-requested no longer comes through transitions()

    @Test
    func changesRequestedNeverEmittedByTransitions() {
        // The stateless `needsRefine` rule in `IssueTracker` is the sole
        // emitter of `.changesRequested` post-CROW-508. `transitions()` must
        // never produce one — guarding against accidental reintroduction.
        let old = status(review: .reviewRequired)
        let new = status(review: .changesRequested)
        let ts = compute(from: old, to: new)
        #expect(!ts.contains(where: { $0.kind == .changesRequested }))
    }
}
