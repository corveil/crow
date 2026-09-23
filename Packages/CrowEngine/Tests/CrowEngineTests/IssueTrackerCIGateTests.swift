import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import CrowEngine

/// CROW-3716 / ADR 0082 — Crow must understand corveil/corveil's fail-closed
/// `CI Gate`:
///   * `buildPRStatus` must not report an *expected* `CI Gate` red as failing,
///     so the `.checksFailing` transition (and its notification /
///     respond-to-failed-checks dispatch) never fires on a pre-approval or
///     in-flight PR (point 4); and
///   * the auto-merge watcher must treat `CI Gate` like any required check —
///     never direct-merging while it's red/pending, and never bailing on the
///     native path (point 3).
@Suite("IssueTracker CI Gate awareness (CROW-3716)")
struct IssueTrackerCIGateTests {

    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "1D76DB")
    private static let ciFullLabel = LabelInfo(name: "ci:full", color: "0E8A16")

    private func makePR(
        state: String = "OPEN",
        mergeable: String = "MERGEABLE",
        mergeStateStatus: String = "CLEAN",
        reviewDecision: String = "APPROVED",
        isDraft: Bool = false,
        checksState: String = "SUCCESS",
        failedCheckNames: [String] = [],
        labels: [LabelInfo] = [],
        ciGatePresent: Bool = true,
        anyCheckPending: Bool = false,
        repoAutoMergeAllowed: Bool? = false
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: 1,
            url: "https://github.com/corveil/corveil/pull/1",
            state: state,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: "feature/x",
            headRefOid: "abc1234",
            baseRefName: "main",
            repoNameWithOwner: "corveil/corveil",
            labels: labels,
            linkedIssueReferences: [],
            checksState: checksState,
            failedCheckNames: failedCheckNames,
            latestReviewStates: ["APPROVED"],
            repoAutoMergeAllowed: repoAutoMergeAllowed,
            ciGatePresent: ciGatePresent,
            anyCheckPending: anyCheckPending
        )
    }

    private func makeSession(autoMergeEnabledAt: Date? = nil) -> Session {
        Session(id: UUID(), name: "session", autoMergeEnabledAt: autoMergeEnabledAt)
    }

    // MARK: - Point 4: buildPRStatus does not chase an expected CI Gate red

    @Test func preApprovalCIGateRedIsNotFailing() {
        // ci:full absent ⇒ the fail-closed gate is red "on purpose". Report it
        // as not-yet-run, not a regression.
        let status = IssueTracker.buildPRStatus(from: makePR(
            checksState: "FAILURE", failedCheckNames: ["CI Gate"], labels: []))
        #expect(status.checksPass != .failing)
        #expect(status.checksPass == .unknown)
        #expect(status.failedCheckNames.isEmpty)
        #expect(status.usesCIGate)
    }

    @Test func inFlightCIGateRedReadsAsPending() {
        // ci:full present, suite still running: don't act — acting cancels the
        // run about to go green.
        let status = IssueTracker.buildPRStatus(from: makePR(
            checksState: "FAILURE", failedCheckNames: ["CI Gate"],
            labels: [Self.ciFullLabel], anyCheckPending: true))
        #expect(status.checksPass == .pending)
        #expect(status.failedCheckNames.isEmpty)
    }

    @Test func realGatedFailureIsFailing() {
        // ci:full present, run settled, a gated job failed with its own red —
        // the one state where the gate red is real.
        let status = IssueTracker.buildPRStatus(from: makePR(
            checksState: "FAILURE",
            failedCheckNames: ["Test (PostgreSQL)", "CI Gate"],
            labels: [Self.ciFullLabel, Self.crowMergeLabel]))
        #expect(status.checksPass == .failing)
        #expect(status.failedCheckNames == ["Test (PostgreSQL)", "CI Gate"])
    }

    @Test func nonConventionRepoIsUnaffected() {
        // No `CI Gate` check ⇒ identical to the pre-CROW-3716 behaviour: a
        // failing check is failing, and the PR does not read as using the
        // convention.
        let status = IssueTracker.buildPRStatus(from: makePR(
            checksState: "FAILURE", failedCheckNames: ["lint"], ciGatePresent: false))
        #expect(status.checksPass == .failing)
        #expect(status.failedCheckNames == ["lint"])
        #expect(!status.usesCIGate)
    }

    // MARK: - Point 4 end-to-end: the .checksFailing transition is suppressed

    @Test func expectedCIGateRedFiresNoChecksFailingTransition() {
        let sessionID = UUID()
        let prURL = "https://github.com/corveil/corveil/pull/1"
        // Was pending, now the (expected) pre-approval CI Gate red.
        let before = IssueTracker.buildPRStatus(from: makePR(checksState: "PENDING"))
        let after = IssueTracker.buildPRStatus(from: makePR(
            checksState: "FAILURE", failedCheckNames: ["CI Gate"], labels: []))
        let transitions = PRStatus.transitions(
            from: before, to: after, sessionID: sessionID, prURL: prURL, prNumber: 1)
        #expect(transitions.isEmpty)
    }

    @Test func realGatedFailureFiresChecksFailingTransition() {
        let sessionID = UUID()
        let prURL = "https://github.com/corveil/corveil/pull/1"
        let before = IssueTracker.buildPRStatus(from: makePR(checksState: "PENDING"))
        let after = IssueTracker.buildPRStatus(from: makePR(
            checksState: "FAILURE",
            failedCheckNames: ["Test (PostgreSQL)", "CI Gate"],
            labels: [Self.ciFullLabel]))
        let transitions = PRStatus.transitions(
            from: before, to: after, sessionID: sessionID, prURL: prURL, prNumber: 1)
        #expect(transitions.count == 1)
        #expect(transitions.first?.kind == .checksFailing)
        #expect(transitions.first?.failedCheckNames == ["Test (PostgreSQL)", "CI Gate"])
    }

    // MARK: - Point 3: the auto-merge watcher waits for CI Gate green

    @Test func neverDirectMergesWhileCIGateIsPending() {
        // ci:full + crow:merge + approved, but the gate is still running: Crow
        // must NOT merge before `CI Gate` has run on the current SHA.
        let pr = makePR(
            checksState: "PENDING",
            labels: [Self.crowMergeLabel, Self.ciFullLabel],
            anyCheckPending: true)
        #expect(!IssueTracker.shouldDirectMerge(pr: pr, session: makeSession()))
    }

    @Test func neverDirectMergesWhileCIGateIsRed() {
        let pr = makePR(
            mergeStateStatus: "BLOCKED",
            checksState: "FAILURE",
            failedCheckNames: ["CI Gate"],
            labels: [Self.crowMergeLabel, Self.ciFullLabel])
        #expect(!IssueTracker.shouldDirectMerge(pr: pr, session: makeSession()))
    }

    @Test func directMergesOnceCIGateIsGreen() {
        // SUCCESS + CLEAN + APPROVED on a repo that forbids GitHub auto-merge:
        // the gate is green on the current tip, so Crow may merge.
        let pr = makePR(labels: [Self.crowMergeLabel, Self.ciFullLabel])
        #expect(IssueTracker.shouldDirectMerge(pr: pr, session: makeSession()))
    }

    @Test func nativeAutoMergeEnablesWhileCIGatePendingRatherThanBailing() {
        // The native path hands the PR to GitHub's queue and lets GitHub enforce
        // `CI Gate` — so Crow stays eligible to enable auto-merge even while the
        // gate is pending, instead of concluding "no required check / not
        // passing" and bailing (CROW-3716 point 3a).
        let pr = makePR(
            mergeStateStatus: "BLOCKED",
            checksState: "PENDING",
            labels: [Self.crowMergeLabel, Self.ciFullLabel],
            anyCheckPending: true)
        #expect(IssueTracker.shouldAttemptAutoMerge(pr: pr, session: makeSession()))
    }
}
