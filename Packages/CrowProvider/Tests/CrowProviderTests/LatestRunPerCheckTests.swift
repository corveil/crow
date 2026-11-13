import XCTest
import CrowCore
@testable import CrowProvider

/// CROW-1454: `statusCheckRollup.contexts` lists every run on the head,
/// superseded ones included. `parsePRNode` must classify only the latest run of
/// each check, or a stale `CI Gate` red plus the cancelled jobs of the run it
/// superseded read as a real, corroborated failure on a PR whose latest run of
/// everything passed.
final class LatestRunPerCheckTests: XCTestCase {

    private func checkRun(
        _ name: String, _ conclusion: String?, status: String = "COMPLETED",
        startedAt: String?, workflow: String? = "Tests"
    ) -> [String: Any] {
        var node: [String: Any] = ["__typename": "CheckRun", "name": name, "status": status]
        node["conclusion"] = conclusion ?? NSNull()
        if let startedAt { node["startedAt"] = startedAt }
        if let workflow {
            node["checkSuite"] = ["workflowRun": ["workflow": ["name": workflow]]]
        }
        return node
    }

    private func prNode(contexts: [[String: Any]], labels: [String] = ["ci:full"]) -> [String: Any] {
        [
            "number": 1, "url": "https://github.com/a/b/pull/1", "state": "OPEN",
            "repository": ["nameWithOwner": "a/b"],
            "labels": ["nodes": labels.map { ["name": $0, "color": "0E8A16"] }],
            "statusCheckRollup": ["state": "FAILURE", "contexts": ["nodes": contexts]],
        ]
    }

    /// The rollup from the ticket: two superseded `CI Gate` reds, cancelled
    /// jobs from the superseded runs, and the latest run of every check green.
    /// Listed out of time order, so the reduction can't lean on position.
    static let ticketRollup: [(String, String, String)] = [
        ("CI Gate", "SUCCESS", "2026-11-13T05:30:39Z"),
        ("Lint", "CANCELLED", "2026-11-13T02:31:51Z"),
        ("CI Gate", "FAILURE", "2026-11-13T02:33:18Z"),
        ("Quick checks", "CANCELLED", "2026-11-13T02:31:51Z"),
        ("Test (PostgreSQL)", "CANCELLED", "2026-11-13T02:32:01Z"),
        ("CI Gate", "FAILURE", "2026-11-13T02:35:39Z"),
        ("Test (PostgreSQL)", "CANCELLED", "2026-11-13T02:33:23Z"),
        ("CI Gate", "SUCCESS", "2026-11-13T02:45:00Z"),
        ("Lint", "SUCCESS", "2026-11-13T05:20:02Z"),
        ("Quick checks", "SUCCESS", "2026-11-13T05:20:02Z"),
        ("Test (PostgreSQL)", "SUCCESS", "2026-11-13T05:20:11Z"),
    ]

    func testSupersededCIGateRedsAndCancelsDoNotReadAsFailure() throws {
        let contexts = Self.ticketRollup.map { checkRun($0.0, $0.1, startedAt: $0.2) }
        let rec = try XCTUnwrap(GitHubCodeBackend.parsePRNode(prNode(contexts: contexts)))
        XCTAssertEqual(rec.checksState, "FAILURE")         // GitHub's aggregate, untouched
        XCTAssertTrue(rec.ciGatePresent)
        XCTAssertFalse(rec.anyCheckPending)
        XCTAssertEqual(rec.failedCheckNames, [])
        XCTAssertFalse(rec.hasNonGateTerminalNonSuccess)
        // So the convention filter has nothing to report.
        XCTAssertEqual(CIGateConvention.actionableFailedChecks(
            rawFailed: rec.failedCheckNames,
            ciFullPresent: CIGateConvention.hasFullSuiteLabel(rec.labels),
            hasOtherTerminalNonSuccess: rec.hasNonGateTerminalNonSuccess), [])
    }

    func testLatestCIGateRedWithLatestGatedFailureIsStillReported() throws {
        // A genuine failure: the newest run's gate and a gated job are red, and
        // an older run on the same head had passed.
        let contexts = [
            checkRun("CI Gate", "SUCCESS", startedAt: "2026-11-13T02:45:00Z"),
            checkRun("Test (PostgreSQL)", "SUCCESS", startedAt: "2026-11-13T02:40:00Z"),
            checkRun("CI Gate", "FAILURE", startedAt: "2026-11-13T05:30:39Z"),
            checkRun("Test (PostgreSQL)", "FAILURE", startedAt: "2026-11-13T05:20:11Z"),
        ]
        let rec = try XCTUnwrap(GitHubCodeBackend.parsePRNode(prNode(contexts: contexts)))
        XCTAssertEqual(rec.failedCheckNames, ["CI Gate", "Test (PostgreSQL)"])
        XCTAssertTrue(rec.hasNonGateTerminalNonSuccess)
        XCTAssertEqual(CIGateConvention.actionableFailedChecks(
            rawFailed: rec.failedCheckNames, ciFullPresent: true,
            hasOtherTerminalNonSuccess: rec.hasNonGateTerminalNonSuccess),
            ["CI Gate", "Test (PostgreSQL)"])
    }

    func testLatestGatedCancelCorroboratesLatestCIGateRed() throws {
        let contexts = [
            checkRun("Test (PostgreSQL)", "SUCCESS", startedAt: "2026-11-13T02:40:00Z"),
            checkRun("Test (PostgreSQL)", "CANCELLED", startedAt: "2026-11-13T05:20:11Z"),
            checkRun("CI Gate", "FAILURE", startedAt: "2026-11-13T05:30:39Z"),
        ]
        let rec = try XCTUnwrap(GitHubCodeBackend.parsePRNode(prNode(contexts: contexts)))
        XCTAssertEqual(rec.failedCheckNames, ["CI Gate"])
        XCTAssertTrue(rec.hasNonGateTerminalNonSuccess)
    }

    func testQueuedRerunWithoutTimestampsBeatsCompletedRun() throws {
        // A re-run that hasn't started yet has no startedAt. It replaces the
        // completed red, so the check is pending, not failed.
        let contexts = [
            checkRun("Test (PostgreSQL)", "FAILURE", startedAt: "2026-11-13T05:20:11Z"),
            checkRun("Test (PostgreSQL)", nil, status: "QUEUED", startedAt: nil),
        ]
        let rec = try XCTUnwrap(GitHubCodeBackend.parsePRNode(prNode(contexts: contexts, labels: [])))
        XCTAssertTrue(rec.anyCheckPending)
        XCTAssertEqual(rec.failedCheckNames, [])
    }

    func testSameJobNameInTwoWorkflowsStaysSeparate() throws {
        let contexts = [
            checkRun("Lint", "FAILURE", startedAt: "2026-11-13T05:00:00Z", workflow: "Docs"),
            checkRun("Lint", "SUCCESS", startedAt: "2026-11-13T05:10:00Z", workflow: "Tests"),
        ]
        let rec = try XCTUnwrap(GitHubCodeBackend.parsePRNode(prNode(contexts: contexts, labels: [])))
        XCTAssertEqual(rec.failedCheckNames, ["Lint"])
    }

    func testStatusContextsReduceByCreatedAt() {
        let nodes: [[String: Any]] = [
            ["__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS",
             "createdAt": "2026-11-13T05:00:00Z"],
            ["__typename": "StatusContext", "context": "ci/legacy", "state": "FAILURE",
             "createdAt": "2026-11-13T02:00:00Z"],
        ]
        let kept = GitHubCodeBackend.latestRunPerCheck(nodes)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?["state"] as? String, "SUCCESS")
    }

    func testDistinctChecksWithoutTimestampsAreAllKeptInOrder() {
        // The shape every pre-CROW-1454 fixture has: no timestamps, no suite.
        let nodes: [[String: Any]] = [
            ["__typename": "CheckRun", "name": "CI Gate", "conclusion": "FAILURE", "status": "COMPLETED"],
            ["__typename": "CheckRun", "name": "Lint", "conclusion": "SUCCESS", "status": "COMPLETED"],
            ["__typename": "StatusContext", "context": "ci/legacy", "state": "SUCCESS"],
        ]
        let kept = GitHubCodeBackend.latestRunPerCheck(nodes)
        XCTAssertEqual(kept.compactMap { ($0["name"] ?? $0["context"]) as? String },
                       ["CI Gate", "Lint", "ci/legacy"])
    }

    func testMonitoredQuerySelectsWhatTheReductionNeeds() {
        // The prStates query is asserted in BackendsTests (#885 test).
        let query = GitHubCodeBackend.monitoredViewerPRsQuery
        XCTAssertTrue(query.contains("contexts(first: 100)"))
        XCTAssertTrue(query.contains("startedAt completedAt"))
        XCTAssertTrue(query.contains("workflowRun { workflow { name } }"))
        XCTAssertTrue(query.contains("... on StatusContext { context state createdAt }"))
    }
}
