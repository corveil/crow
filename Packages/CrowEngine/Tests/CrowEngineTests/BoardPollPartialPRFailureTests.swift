import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// CROW-1349: when `listMonitoredPRs` fails but `listAssigned` succeeds, the
/// poll keeps the issue listing instead of discarding the whole cycle. The
/// issue-side rules (ticket board, closed-issue auto-complete) keep running;
/// the PR side keeps its previous snapshot and never completes a session on
/// missing data.
@Suite("Board poll keeps issues when the PR query fails (CROW-1349)")
@MainActor
struct BoardPollPartialPRFailureTests {

    private struct StubError: Error {}

    private struct StubTaskBackend: TaskBackend {
        let listing: AssignedListing
        let provider: Provider = .github
        let capabilities: Set<TaskCapability> = []
        func fetchTask(url: String) async throws -> TicketInfo { throw StubError() }
        func listAssigned(includeClosed: Bool) async throws -> AssignedListing { listing }
        func setLabels(url: String, add: [String], remove: [String]) async throws {}
        func setTaskStatus(url: String, status: TicketStatus) async throws {}
        func closeTask(url: String) async throws {}
        func assign(url: String, to login: String) async throws {}
        func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo {
            throw StubError()
        }
    }

    /// `listMonitoredPRs` always throws — the 2026-10-22 GitHub 502.
    private struct FailingPRBackend: CodeBackend {
        let provider: Provider = .github
        let cliName = "gh"
        let capabilities: Set<CodeCapability> = []
        func linkedPR(repo: String, branch: String) async throws -> LinkedPR? { nil }
        func ensureMergeLabel(repo: String) async throws {}
        func listMonitoredPRs() async throws -> MonitoredPRListing { throw StubError() }
        func prStates(refs: [PRRef], viewerLogin: String?) async throws -> [PRRef: PRRecord] { [:] }
        func fetchCrowAuthoredCommits(prURL: String, repoSlug: String, prNumber: Int) async throws -> [CommitInfo] { [] }
        func findRecentPRsForBranches(_ candidates: [BranchCandidate]) async throws -> [BranchPRMatch] { [] }
        func enableAutoMerge(prURL: String) async throws {}
        func updateBranch(prURL: String) async throws {}
        func fetchPRMetadata(prURL: String) async throws -> PRMetadata {
            PRMetadata(title: "", number: 0, headRefName: "", headRefOid: "", baseRefName: "")
        }
    }

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-partial-pr-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private static func issue(_ number: Int, state: String) -> AssignedIssue {
        AssignedIssue(
            id: "github:corveil/crow#\(number)",
            number: number,
            title: "issue \(number)",
            state: state,
            url: "https://github.com/corveil/crow/issues/\(number)",
            repo: "corveil/crow",
            provider: .github
        )
    }

    private static func pr(_ number: Int, state: String) -> PRRecord {
        PRRecord(
            number: number,
            url: "https://github.com/corveil/crow/pull/\(number)",
            state: state,
            isDraft: false,
            repoNameWithOwner: "corveil/crow"
        )
    }

    // MARK: - Fetch

    @Test func prQueryFailureKeepsTheIssueListing() async {
        let listing = AssignedListing(
            open: [Self.issue(1, state: "open")],
            closed: [Self.issue(2, state: "closed")]
        )
        let (response, events) = await BoardPoller.runConsolidatedGitHubQuery(
            taskBackend: StubTaskBackend(listing: listing),
            codeBackend: FailingPRBackend()
        )

        let result = response
        #expect(result?.prDataAvailable == false)
        #expect(result?.openIssues.map(\.number) == [1])
        #expect(result?.closedIssues.map(\.number) == [2])
        #expect(result?.viewerPRs.isEmpty == true)
        #expect(result?.reviewRequests.isEmpty == true)
        #expect(events.contains { if case .failed(operation: "listMonitoredPRs", _) = $0 { true } else { false } })
        // The PR half's warning state is unknown, so nothing is cleared.
        #expect(!events.contains(.clearScopeWarning))
        #expect(!events.contains(.clearSAMLWarning))
    }

    @Test func issueQueryFailureStillDropsTheCycle() async {
        struct FailingTaskBackend: TaskBackend {
            let provider: Provider = .github
            let capabilities: Set<TaskCapability> = []
            func fetchTask(url: String) async throws -> TicketInfo { throw StubError() }
            func listAssigned(includeClosed: Bool) async throws -> AssignedListing { throw StubError() }
            func setLabels(url: String, add: [String], remove: [String]) async throws {}
            func setTaskStatus(url: String, status: TicketStatus) async throws {}
            func closeTask(url: String) async throws {}
            func assign(url: String, to login: String) async throws {}
            func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo {
                throw StubError()
            }
        }
        let (response, _) = await BoardPoller.runConsolidatedGitHubQuery(
            taskBackend: FailingTaskBackend(),
            codeBackend: FailingPRBackend()
        )
        #expect(response == nil)
    }

    // MARK: - Apply

    private static func partialFetch(
        open: [AssignedIssue],
        closed: [AssignedIssue],
        stale: BoardPoller.StalePRFetchResult
    ) -> BoardPoller.BoardPollFetch {
        let (response, events) = BoardPoller.partialResponseWithoutPRs(
            assigned: AssignedListing(open: open, closed: closed),
            events: [.failed(operation: "listMonitoredPRs", message: "HTTP 502")]
        )
        return BoardPoller.BoardPollFetch(
            issues: open + closed,
            doneCount: closed.count,
            ghResult: response,
            githubEvents: events,
            staleFetch: stale
        )
    }

    private struct Harness {
        let tracker: IssueTracker
        let state: AppState
        let issueOnly: UUID
        let prLinked: UUID
        var completed: [UUID] { completedBox.ids }
        let completedBox: CompletedBox
    }

    final class CompletedBox { var ids: [UUID] = [] }

    /// Two sessions whose issues (#10, #11) both closed: one issue-only, one
    /// with a PR link (#20). Issue #12 stays open so the floor guard is clear.
    private func makeHarness() -> Harness {
        let state = AppState()
        let issueOnly = Session(name: "issue-only", ticketURL: Self.issue(10, state: "closed").url, provider: .github)
        let prLinked = Session(name: "pr-linked", ticketURL: Self.issue(11, state: "closed").url, provider: .github)
        state.sessions = [issueOnly, prLinked]
        state.links[prLinked.id] = [
            SessionLink(sessionID: prLinked.id, label: "PR #20", url: Self.pr(20, state: "OPEN").url, linkType: .pr)
        ]
        let box = CompletedBox()
        state.onCompleteSession = { box.ids.append($0) }
        let tracker = IssueTracker(appState: state, providerManager: ProviderManager(), store: Self.tempStore())
        return Harness(tracker: tracker, state: state, issueOnly: issueOnly.id, prLinked: prLinked.id, completedBox: box)
    }

    @Test func closedIssueCompletesIssueOnlySessionButNotOnMissingPRData() {
        let h = makeHarness()
        let fetch = Self.partialFetch(
            open: [Self.issue(12, state: "open")],
            closed: [Self.issue(10, state: "closed"), Self.issue(11, state: "closed")],
            stale: .init(prs: [], complete: false)
        )

        h.tracker.applyFetchedBoard(fetch, config: AppConfig())

        // The ticket board still shows the issues.
        #expect(h.state.assignedIssues.map(\.number) == [12, 10, 11])
        // Issue-only session completes on its closed issue; the PR-linked one
        // waits, because its PR state is unknown this cycle.
        #expect(h.completed == [h.issueOnly])
    }

    @Test func stalePRLookupGivesPRLinkedSessionsPositiveEvidence() {
        let h = makeHarness()
        let fetch = Self.partialFetch(
            open: [Self.issue(12, state: "open")],
            closed: [Self.issue(10, state: "closed"), Self.issue(11, state: "closed")],
            stale: .init(prs: [Self.pr(20, state: "MERGED")], complete: true)
        )

        h.tracker.applyFetchedBoard(fetch, config: AppConfig())

        #expect(Set(h.completed) == [h.issueOnly, h.prLinked])
    }

    @Test func prSideSnapshotIsPreservedAcrossThePartialCycle() {
        let h = makeHarness()
        let review = ReviewRequest(
            id: "github:corveil/crow#30", prNumber: 30, title: "review me",
            url: "https://github.com/corveil/crow/pull/30", repo: "corveil/crow",
            author: "someone", headBranch: "feature/x", baseBranch: "main"
        )
        h.state.reviewRequests = [review]
        var previous = Self.issue(12, state: "open")
        previous.prNumber = 21
        previous.prURL = "https://github.com/corveil/crow/pull/21"
        previous.prState = "open"
        previous.checksState = "SUCCESS"
        h.state.assignedIssues = [previous]

        let fetch = Self.partialFetch(
            open: [Self.issue(12, state: "open")],
            closed: [],
            stale: .init(prs: [], complete: false)
        )
        h.tracker.applyFetchedBoard(fetch, config: AppConfig())

        // Review board is not blanked by the empty (unknown) PR arrays.
        #expect(h.state.reviewRequests.map(\.id) == [review.id])
        // The issue keeps last cycle's PR badge.
        #expect(h.state.assignedIssues.first?.prNumber == 21)
        #expect(h.state.assignedIssues.first?.checksState == "SUCCESS")
        #expect(h.completed.isEmpty)
    }

    @Test func carryOverLeavesFreshAndNonOpenIssuesAlone() {
        var previous = Self.issue(1, state: "open")
        previous.prURL = "https://github.com/corveil/crow/pull/9"
        previous.prNumber = 9
        var fresh = Self.issue(1, state: "open")
        fresh.prURL = "https://github.com/corveil/crow/pull/99"
        fresh.prNumber = 99

        #expect(BoardPoller.carryOverPRFields([fresh], from: [previous]).first?.prNumber == 99)
        #expect(BoardPoller.carryOverPRFields([Self.issue(1, state: "closed")], from: [previous]).first?.prURL == nil)
        #expect(BoardPoller.carryOverPRFields([Self.issue(1, state: "open")], from: [previous]).first?.prNumber == 9)
    }
}
