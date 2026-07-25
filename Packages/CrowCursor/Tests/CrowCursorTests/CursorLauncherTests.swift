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
}
