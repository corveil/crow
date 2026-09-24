import Foundation
import Testing
@testable import CrowCore

/// ADR 0082 / CROW-3716: Crow must read corveil/corveil's fail-closed `CI Gate`
/// correctly — a `CI Gate` red is expected (not a failure to chase) unless the
/// suite actually ran and a gated job did not succeed. The name filter that
/// decides this (for an already-settled run) is pure, so it is pinned here.
/// The pending → not-actionable rule lives in `buildPRStatus` and is covered by
/// `IssueTrackerCIGateTests`.
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

    // MARK: - terminalNonSuccessConclusions covers timeout/cancel, not skip

    @Test func timeoutAndCancelAreTerminalNonSuccess() {
        #expect(CIGateConvention.terminalNonSuccessConclusions.contains("TIMED_OUT"))
        #expect(CIGateConvention.terminalNonSuccessConclusions.contains("CANCELLED"))
        #expect(CIGateConvention.terminalNonSuccessConclusions.contains("FAILURE"))
        // GitHub counts these as passing for a required check — never corroborate.
        #expect(!CIGateConvention.terminalNonSuccessConclusions.contains("SKIPPED"))
        #expect(!CIGateConvention.terminalNonSuccessConclusions.contains("SUCCESS"))
        #expect(!CIGateConvention.terminalNonSuccessConclusions.contains("NEUTRAL"))
    }

    // MARK: - actionableFailedChecks: the no-op case (every non-convention repo)

    @Test func leavesNonCIGateFailuresUntouched() {
        // No `CI Gate` in the list ⇒ identical output. The crow repo's own CI
        // and every other workspace.
        let raw = ["Lint", "Test (PostgreSQL)"]
        #expect(CIGateConvention.actionableFailedChecks(rawFailed: raw, ciFullPresent: false, hasOtherTerminalNonSuccess: false) == raw)
        #expect(CIGateConvention.actionableFailedChecks(rawFailed: raw, ciFullPresent: true, hasOtherTerminalNonSuccess: true) == raw)
        #expect(CIGateConvention.actionableFailedChecks(rawFailed: [], ciFullPresent: false, hasOtherTerminalNonSuccess: false) == [])
    }

    // MARK: - actionableFailedChecks: expected reds are dropped

    @Test func dropsPreApprovalCIGateRed() {
        // ci:full absent ⇒ the six workers skipped and `CI Gate` failed closed.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate"], ciFullPresent: false, hasOtherTerminalNonSuccess: false) == [])
    }

    @Test func dropsStaleCIGateRedWhenNoGatedJobFailed() {
        // Settled, ci:full present, but every other check is green/skipped — a
        // lone `CI Gate` red is a stale conclusion (the window after the workers
        // finish but before the post-label gate is recreated), not a failure.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate"], ciFullPresent: true, hasOtherTerminalNonSuccess: false) == [])
    }

    @Test func dropsCIGateButKeepsRealNonGateFailurePreApproval() {
        // Even pre-approval, a genuinely failing non-gate check stays actionable;
        // only the expected `CI Gate` red is filtered.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate", "static-guard"], ciFullPresent: false, hasOtherTerminalNonSuccess: true)
            == ["static-guard"])
    }

    // MARK: - actionableFailedChecks: real, corroborated failures are kept

    @Test func keepsRealPostLabelFailureWithFailingSibling() {
        // ci:full present, a gated job's own red is in the list — both names stay.
        let raw = ["Test (PostgreSQL)", "CI Gate"]
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: raw, ciFullPresent: true, hasOtherTerminalNonSuccess: true) == raw)
    }

    @Test func keepsCIGateRedCorroboratedByTimeoutNotInNames() {
        // Yellow (review of #1300): a gated job that TIMED_OUT/CANCELLED never
        // enters `failedCheckNames`, so the only name is `CI Gate`. The terminal
        // non-success sibling still corroborates it as a real failure.
        #expect(CIGateConvention.actionableFailedChecks(
            rawFailed: ["CI Gate"], ciFullPresent: true, hasOtherTerminalNonSuccess: true) == ["CI Gate"])
    }
}
