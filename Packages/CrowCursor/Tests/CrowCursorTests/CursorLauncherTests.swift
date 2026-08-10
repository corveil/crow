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
        #expect(cmd.contains("_CROW_P=$(< "))
        #expect(cmd.contains("eval \"'agent' --trust $(printf '%q'"))
        #expect(cmd.contains("--force") == false)          // no auto-permission
    }

    @Test func launchCommandWithholdsTrustSeedWhenSeedTrustOff() async throws {
        // The `seedTrust: false` arm has no production caller as of CROW-954 (every
        // Cursor launch now seeds, `.review` included), but the parameter is kept
        // so the withholding posture stays one flag flip away — see
        // `CursorLaunchArgs.launchSuffix`. Pin the arm so it can't silently rot
        // into a no-op that would make restoring it a lie.
        let cmd = try await CursorLauncher().launchCommand(
            sessionID: UUID(), worktreePath: "/w", prompt: "p", seedTrust: false)
        #expect(cmd.contains("--trust") == false)
        #expect(cmd.contains("eval \"'agent' $(printf '%q'"))
    }
}
