import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import CrowEngine

/// Minimal `CodeBackend` for prompt-rendering tests — only `provider` and
/// `cliName` are read by the builders. The other protocol methods are
/// unused, so trivial stubs are fine.
private struct FakeCodeBackend: CodeBackend {
    let provider: Provider
    let cliName: String
    let capabilities: Set<CodeCapability> = []
    func linkedPR(repo: String, branch: String) async throws -> LinkedPR? { nil }
    func ensureMergeLabel(repo: String) async throws {}
    func listMonitoredPRs() async throws -> MonitoredPRListing {
        MonitoredPRListing(viewerPRs: [], reviewRequests: [], viewerLogin: "")
    }
    func prStates(refs: [PRRef]) async throws -> [PRRef: PRRecord] { [:] }
    func fetchCrowAuthoredCommits(prURL: String, repoSlug: String, prNumber: Int) async throws -> [CommitInfo] { [] }
    func findRecentPRsForBranches(_ candidates: [BranchCandidate]) async throws -> [BranchPRMatch] { [] }
    func enableAutoMerge(prURL: String) async throws {}
    func updateBranch(prURL: String) async throws {}
    func fetchPRMetadata(prURL: String) async throws -> PRMetadata {
        PRMetadata(title: "", number: 0, headRefName: "", headRefOid: "", baseRefName: "")
    }
}

@Suite("QuickActionPrompts.mergePR")
struct QuickActionPromptsTests {

    @Test func githubMergeHintRunsFromTmpdirToAvoidWorktreeConflict() {
        let prompt = QuickActionPrompts.build(
            action: .mergePR,
            codeBackend: FakeCodeBackend(provider: .github, cliName: "gh"),
            prURL: "https://github.com/radiusmethod/crow/pull/123",
            prNumber: 123
        )
        #expect(prompt.contains("cd \"$TMPDIR\" && gh pr merge https://github.com/radiusmethod/crow/pull/123 --squash --delete-branch"))
        #expect(prompt.contains("worktree"))
        #expect(prompt.hasSuffix("\n"))
    }

    @Test func gitlabMergeHintIsUnaffected() {
        let prompt = QuickActionPrompts.build(
            action: .mergePR,
            codeBackend: FakeCodeBackend(provider: .gitlab, cliName: "glab"),
            prURL: "https://gitlab.example.com/org/repo/-/merge_requests/45",
            prNumber: 45
        )
        #expect(prompt.contains("glab mr merge https://gitlab.example.com/org/repo/-/merge_requests/45"))
        #expect(!prompt.contains("$TMPDIR"))
        #expect(prompt.hasSuffix("\n"))
    }
}

/// A manual quick action must report whether it actually reached the agent so
/// the web UI stops echoing a false "dispatched" for silent no-ops (#730).
@Suite("AutoRespondCoordinator.dispatchManual")
@MainActor
struct DispatchManualResultTests {

    @Test func skipsWithNoManagedTerminalWhenSessionHasNone() {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        let coordinator = AutoRespondCoordinator(
            appState: appState, providerManager: ProviderManager(),
            settingsProvider: { AutoRespondSettings() })
        #expect(coordinator.dispatchManual(action: .mergePR, sessionID: session.id) == .noManagedTerminal)
    }

    @Test func skipReasonIsNilOnlyWhenSent() {
        #expect(QuickActionDispatchResult.sent.isSent)
        #expect(QuickActionDispatchResult.sent.skipReason == nil)
        for result in [QuickActionDispatchResult.noManagedTerminal, .surfaceNotReady, .noPRLink] {
            #expect(!result.isSent)
            #expect(result.skipReason?.isEmpty == false)
        }
    }
}
