import Foundation
import Testing
@testable import CrowCore

/// ADR 0082 / CROW-3716: Crow must read corveil/corveil's fail-closed `CI Gate`
/// correctly — a `CI Gate` red is expected (not a failure to chase) unless the
/// suite actually ran and a gated job failed. The classifier that decides this
/// is pure, so it is pinned here across every state of decision 5's table.
@Suite("CIGateConvention: label + actionable-failure classifier")
struct CIGateConventionTests {

    private func label(_ name: String) -> LabelInfo { LabelInfo(name: name, color: nil) }

    // MARK: - hasFullSuiteLabel

    @Test func detectsFullSuiteLabel() {
        #expect(CIGateConvention.hasFullSuiteLabel([label("ci:full")]))
        #expect(CIGateConvention.hasFullSuiteLabel([label("crow:merge"), label("ci:full")]))
    }

    @Test func matchesFullSuiteLabelCaseInsensitively() {
        #expect(CIGateConvention.hasFullSuiteLabel([label("CI:Full")]))
    }

    @Test func absentFullSuiteLabel() {
        #expect(!CIGateConvention.hasFullSuiteLabel([]))
        #expect(!CIGateConvention.hasFullSuiteLabel([label("crow:merge"), label("bug")]))
    }

    // MARK: - actionableFailedChecks: the no-op case (every non-convention repo)

    @Test func leavesNonCIGateFailuresUntouched() {
        // No `CI Gate` in the list ⇒ identical output, regardless of the flags.
        // This is the crow repo's own CI and every other workspace.
        let raw = ["Lint", "Test (PostgreSQL)"]
        #expect(CIGateConvention.actionableFailedChecks(rawFailed: raw, ciFullPresent: false, anyCheckPending: false) == raw)
        #expect(CIGateConvention.actionableFailedChecks(rawFailed: raw, ciFullPresent: true, anyCheckPending: true) == raw)
        #expect(CIGateConvention.actionableFailedChecks(rawFailed: [], ciFullPresent: false, anyCheckPending: false) == [])
    }

    // MARK: - actionableFailedChecks: the expected reds (decision 5)

    @Test func dropsPreApprovalCIGateRed() {
        // ci:full absent ⇒ the six workers skipped and `CI Gate` failed closed.
        // "CI has not run", not a failure. The acceptance criterion.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate"], ciFullPresent: false, anyCheckPending: false) == [])
    }

    @Test func dropsInFlightCIGateRed() {
        // ci:full present but the post-label suite is still running: `CI Gate`'s
        // real conclusion hasn't posted yet. Acting now would cancel the run.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate"], ciFullPresent: true, anyCheckPending: true) == [])
    }

    @Test func dropsStaleCIGateRedWhenNoGatedJobFailed() {
        // Settled, ci:full present, but every other check is green/skipped — a
        // lone `CI Gate` red is a stale conclusion (the brief window after the
        // workers finish but before the post-label gate is recreated), not a
        // real failure of a gated job.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate"], ciFullPresent: true, anyCheckPending: false) == [])
    }

    @Test func dropsCIGateButKeepsRealNonGateFailurePreApproval() {
        // Even pre-approval, a genuinely failing non-gate check is still real
        // and stays actionable; only the expected `CI Gate` red is filtered.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate", "static-guard"], ciFullPresent: false, anyCheckPending: false)
            == ["static-guard"])
    }

    // MARK: - actionableFailedChecks: the one real, actionable failure

    @Test func keepsRealPostLabelFailure() {
        // ci:full present, run settled, a gated job (its own red) failed — this
        // is the only state where `CI Gate` is a real failure. Both names stay.
        let raw = ["Test (PostgreSQL)", "CI Gate"]
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: raw, ciFullPresent: true, anyCheckPending: false) == raw)
    }
}
