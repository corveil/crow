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

/// The reviewer-side re-review prompt (#757) must re-run the review on the
/// author's latest head, post a verdict, and NEVER instruct the agent to edit
/// code — that's the CROW-551 policy the manual button now honors. Shared with
/// #756's automatic head-advance re-review via `QuickActionPrompts.reReviewPrompt`.
@Suite("QuickActionPrompts.reReview")
struct ReReviewPromptTests {

    @Test func neverInstructsCodeChangesAndAlwaysPostsAVerdict() {
        let prompt = QuickActionPrompts.build(
            action: .reReview,
            codeBackend: FakeCodeBackend(provider: .github, cliName: "gh"),
            prURL: "https://github.com/radiusmethod/crow/pull/753",
            prNumber: 753,
            lastReviewedHeadSha: "abcdef0123456789"
        )
        // Never touch the branch under review.
        #expect(prompt.contains("do NOT modify code, commit, or push"))
        // Re-runs the review + posts a verdict (not a bare comment).
        #expect(prompt.contains("gh pr review https://github.com/radiusmethod/crow/pull/753 --request-changes"))
        #expect(prompt.contains("--approve"))
        #expect(prompt.contains("never `--comment`"))
        // Single-line contract.
        #expect(prompt.hasSuffix("\n"))
        #expect(!prompt.dropLast().contains("\n"))
    }

    @Test func scopesDiffToLastReviewedHeadWhenKnown() {
        let prompt = QuickActionPrompts.build(
            action: .reReview,
            codeBackend: FakeCodeBackend(provider: .github, cliName: "gh"),
            prURL: "https://github.com/radiusmethod/crow/pull/753",
            prNumber: 753,
            lastReviewedHeadSha: "abcdef0123456789deadbeef"
        )
        // Short SHA (12 chars) scopes the incremental diff.
        #expect(prompt.contains("git diff abcdef012345..HEAD"))
    }

    @Test func fallsBackToFullPRWhenNoLastReviewedHead() {
        let prompt = QuickActionPrompts.build(
            action: .reReview,
            codeBackend: FakeCodeBackend(provider: .github, cliName: "gh"),
            prURL: "https://github.com/radiusmethod/crow/pull/753",
            prNumber: 753,
            lastReviewedHeadSha: nil
        )
        #expect(prompt.contains("Review the whole PR."))
        #expect(!prompt.contains("git diff"))
    }

    @Test func gitlabUsesGlabCli() {
        let prompt = QuickActionPrompts.build(
            action: .reReview,
            codeBackend: FakeCodeBackend(provider: .gitlab, cliName: "glab"),
            prURL: "https://gitlab.example.com/org/repo/-/merge_requests/45",
            prNumber: 45,
            lastReviewedHeadSha: nil
        )
        #expect(prompt.contains("glab mr checkout https://gitlab.example.com/org/repo/-/merge_requests/45"))
        #expect(prompt.contains("do NOT modify code, commit, or push"))
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
        for result in [QuickActionDispatchResult.noManagedTerminal, .surfaceNotReady, .noPRLink, .forbiddenOnReviewSession] {
            #expect(!result.isSent)
            #expect(result.skipReason?.isEmpty == false)
        }
    }

    /// #757 — the manual path must mirror `shouldSkipReviewSession`: a reviewer
    /// clicking a code-changing action on a review session is refused before any
    /// terminal work, so Crow never commits to the branch under review.
    @Test func refusesCodeChangingActionsOnReviewSession() {
        let appState = AppState()
        let review = Session(name: "review-crow-753", kind: .review, agentKind: .cursor)
        appState.sessions = [review]
        let coordinator = AutoRespondCoordinator(
            appState: appState, providerManager: ProviderManager(),
            settingsProvider: { AutoRespondSettings() })
        for action in [QuickAction.addressChanges, .fixChecks, .fixConflicts] {
            #expect(coordinator.dispatchManual(action: action, sessionID: review.id) == .forbiddenOnReviewSession)
        }
    }

    /// `reReview` is the reviewer's affordance — it must NOT be refused on a
    /// review session. With no managed terminal it falls through to the normal
    /// skip result rather than the review guard.
    @Test func reReviewIsAllowedOnReviewSession() {
        let appState = AppState()
        let review = Session(name: "review-crow-753", kind: .review, agentKind: .cursor)
        appState.sessions = [review]
        let coordinator = AutoRespondCoordinator(
            appState: appState, providerManager: ProviderManager(),
            settingsProvider: { AutoRespondSettings() })
        #expect(coordinator.dispatchManual(action: .reReview, sessionID: review.id) == .noManagedTerminal)
    }

    /// Author/work sessions are unaffected — code-changing actions still flow
    /// through (here they reach the no-terminal skip, not the review guard).
    @Test func doesNotRefuseCodeChangingActionsOnWorkSession() {
        let appState = AppState()
        let work = Session(name: "feature-crow-789", kind: .work, agentKind: .claudeCode)
        appState.sessions = [work]
        let coordinator = AutoRespondCoordinator(
            appState: appState, providerManager: ProviderManager(),
            settingsProvider: { AutoRespondSettings() })
        #expect(coordinator.dispatchManual(action: .addressChanges, sessionID: work.id) == .noManagedTerminal)
    }

    @Test func modifiesCodeUnderReviewFlagsOnlyCodeChangingActions() {
        #expect(QuickAction.addressChanges.modifiesCodeUnderReview)
        #expect(QuickAction.fixChecks.modifiesCodeUnderReview)
        #expect(QuickAction.fixConflicts.modifiesCodeUnderReview)
        #expect(!QuickAction.reReview.modifiesCodeUnderReview)
        #expect(!QuickAction.mergePR.modifiesCodeUnderReview)
    }
}
