import Foundation
import Testing
@testable import CrowCursor
@testable import CrowCore

@Suite("CursorLauncher")
struct CursorLauncherTests {
    private func jiraPrompt(_ url: String) async -> String {
        let session = Session(name: "t", agentKind: .cursor)
        let wt = SessionWorktree(
            sessionID: session.id,
            repoName: "repo", repoPath: "/r", worktreePath: "/w", branch: "b")
        return await CursorLauncher().generatePrompt(
            session: session, worktrees: [wt], ticketURL: url,
            provider: .jira, codeProvider: nil)
    }

    @Test func jiraPromptRoutesToMCPNotAcli() async {
        // #829 Yellow 1: the bridged `jira` MCP must actually be used — the
        // prompt should instruct the `jira_*` MCP tools, not a bare `acli` block.
        let prompt = await jiraPrompt("https://x.atlassian.net/browse/CROW-829")
        #expect(prompt.contains("`jira` MCP server"))
        #expect(prompt.contains("jira_get_issue"))
        #expect(prompt.contains("CROW-829"))
        // `acli` may still appear as a documented fallback, but not as the
        // primary bare command block it used to be.
        #expect(prompt.contains("```bash\nacli") == false)
    }

    @Test func jiraPromptWithoutKeyStillMentionsMCP() async {
        let prompt = await jiraPrompt("https://x.atlassian.net/unparseable")
        #expect(prompt.contains("`jira` MCP server") || prompt.contains("jira_get_issue"))
    }

    @Test func launchCommandCarriesTrustSeedNotAutoPermission() async throws {
        // #890: the handoff one-shot is the only seed site that applies
        // `CursorLaunchArgs.trustSuffix` directly (not via `launchSuffix`), so
        // it needs its own assertion — the shared-helper tests can't guard it.
        // With `seedTrust: true` it carries the `--trust` workspace-trust seed
        // but deliberately omits the auto-permission flags (trust is orthogonal
        // to approval).
        let cmd = try await CursorLauncher().launchCommand(
            sessionID: UUID(), worktreePath: "/w", prompt: "p", seedTrust: true)
        #expect(cmd.contains("'agent' --trust \"$(cat "))  // seed, before the prompt
        #expect(cmd.contains("--force") == false)          // no auto-permission
    }

    @Test func launchCommandWithholdsTrustSeedForReviewClone() async throws {
        // CROW-890 review (Red 1): `seedTrust: false` (the `.review` handoff
        // case) drops `--trust` — the binary is followed directly by the prompt,
        // so an attacker-controlled review clone keeps the folder-trust gate.
        let cmd = try await CursorLauncher().launchCommand(
            sessionID: UUID(), worktreePath: "/w", prompt: "p", seedTrust: false)
        #expect(cmd.contains("--trust") == false)
        #expect(cmd.contains("'agent' \"$(cat "))
    }
}
