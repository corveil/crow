import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import CrowEngine

/// CROW-1179: provider I/O for the board poll must not run on MainActor.
/// The shell runner records whether `run` executed on the main thread; a
/// `@MainActor` `BoardPoller` method would inherit that isolation and
/// `Thread.isMainThread` would be true (the `sample` stack the ticket cites).
@Suite("Board poll provider I/O is off MainActor (CROW-1179)")
struct BoardPollOffMainActorTests {

    /// Records the calling thread and fails the command immediately so the
    /// test does not depend on a real `gh` payload. Thread inspection lives
    /// in a synchronous helper because `Thread.isMainThread` is unavailable
    /// from `async` contexts.
    final class RecordingShellRunner: ShellRunner, @unchecked Sendable {
        private nonisolated(unsafe) var _sawMain = false
        private let entered = DispatchSemaphore(value: 0)

        var sawMainThread: Bool { _sawMain }

        func waitUntilEntered() {
            entered.wait()
        }

        func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
            recordIfMain()
            entered.signal()
            throw ShellRunnerError.nonZeroExit(exitCode: 1, output: "recorded")
        }

        private func recordIfMain() {
            if Thread.isMainThread { _sawMain = true }
        }
    }

    @Test func consolidatedGitHubQueryDoesNotRunOnMainThread() async {
        let runner = RecordingShellRunner()
        let task = GitHubTaskBackend(shellRunner: runner)
        let code = GitHubCodeBackend(shellRunner: runner)

        async let fetch = BoardPoller.runConsolidatedGitHubQuery(
            taskBackend: task, codeBackend: code)
        await Task.detached { runner.waitUntilEntered() }.value
        #expect(
            !runner.sawMainThread,
            "runConsolidatedGitHubQuery still inherited MainActor isolation (CROW-1179)"
        )
        _ = await fetch
    }

    @Test func fetchOffActorDoesNotRunOnMainThread() async {
        let runner = RecordingShellRunner()
        let providerManager = ProviderManager(shellRunner: runner)
        let snapshot = BoardPoller.BoardPollSnapshot(
            hasGitHub: true,
            gitLabHosts: [],
            jiraConfigsWithoutAuth: [],
            jiraCredential: nil,
            sessionPRURLs: []
        )

        async let fetch = BoardPoller.fetchOffActor(
            snapshot: snapshot, providerManager: providerManager)
        await Task.detached { runner.waitUntilEntered() }.value
        #expect(
            !runner.sawMainThread,
            "fetchOffActor still inherited MainActor isolation (CROW-1179)"
        )

        let hopStart = Date()
        await MainActor.run {}
        #expect(Date().timeIntervalSince(hopStart) < 0.1)

        let result = await fetch
        #expect(result.ghResult == nil)
        #expect(result.issues.isEmpty)
    }

    @Test func overlappingFetchesDoNotShareMutablePollerState() async {
        // fetchOffActor is a pure static over a Sendable snapshot — two
        // concurrent polls cannot tear appState because they write nothing.
        // IssueTracker.refresh still serializes the apply hop with isRefreshing.
        let runner = RecordingShellRunner()
        let providerManager = ProviderManager(shellRunner: runner)
        let snapshot = BoardPoller.BoardPollSnapshot(
            hasGitHub: true,
            gitLabHosts: [],
            jiraConfigsWithoutAuth: [],
            jiraCredential: nil,
            sessionPRURLs: []
        )
        async let a = BoardPoller.fetchOffActor(
            snapshot: snapshot, providerManager: providerManager)
        async let b = BoardPoller.fetchOffActor(
            snapshot: snapshot, providerManager: providerManager)
        let first = await a
        let second = await b
        #expect(first.issues.isEmpty)
        #expect(second.issues.isEmpty)
        #expect(first.staleFetch.complete)
        #expect(second.staleFetch.complete)
    }

    @Test func enrichOpenIssuesCopiesViewerPRHealthOntoTheMatchingIssue() {
        let issue = AssignedIssue(
            id: "github:corveil/crow#1179",
            number: 1179,
            title: "board poll",
            state: "open",
            url: "https://github.com/corveil/crow/issues/1179",
            repo: "corveil/crow",
            provider: .github
        )
        let pr = PRRecord(
            number: 42,
            url: "https://github.com/corveil/crow/pull/42",
            state: "OPEN",
            isDraft: false,
            repoNameWithOwner: "corveil/crow",
            linkedIssueReferences: [LinkedIssueRef(number: 1179, repo: "corveil/crow")],
            checksState: "FAILURE",
            failedCheckNames: ["ci"]
        )
        let enriched = BoardPoller.enrichOpenIssuesWithViewerPRs([issue], viewerPRs: [pr])
        #expect(enriched[0].prNumber == 42)
        #expect(enriched[0].prURL == pr.url)
        #expect(enriched[0].prState == "open")
        #expect(enriched[0].checksState == "FAILURE")
        #expect(enriched[0].failedCheckNames == ["ci"])
    }

    @Test func githubEventsMapTypedProviderErrors() {
        let scope = BoardPoller.githubEvents(
            from: ProviderError.insufficientScope("read:project"),
            operation: "listAssigned"
        )
        #expect(scope == [.insufficientScope("read:project")])

        let rate = BoardPoller.githubEvents(
            from: ProviderError.rateLimited("rate limit exceeded"),
            operation: "listAssigned"
        )
        #expect(rate == [.rateLimited(stderr: "rate limit exceeded")])
    }
}
