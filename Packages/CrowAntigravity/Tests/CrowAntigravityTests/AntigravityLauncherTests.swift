import Foundation
import Testing
@testable import CrowAntigravity
@testable import CrowCore

@Suite("AntigravityLauncher")
struct AntigravityLauncherTests {
    private let launcher = AntigravityLauncher()

    private func worktree(_ repo: String = "crow", branch: String = "feature/x") -> SessionWorktree {
        SessionWorktree(
            sessionID: UUID(),
            repoName: repo,
            repoPath: "/repos/\(repo)",
            worktreePath: "/wt/\(repo)",
            branch: branch)
    }

    // MARK: - generatePrompt

    @Test func promptIncludesPlanPreambleAndWorkspaceTable() async {
        let session = Session(name: "s", agentKind: .antigravity)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: nil, provider: nil, codeProvider: nil)
        #expect(prompt.contains("sketch a brief plan"))
        #expect(prompt.contains("# Workspace Context"))
        #expect(prompt.contains("| crow | /wt/crow | feature/x | |"))
    }

    @Test func githubTicketUsesGhIssueView() async {
        let session = Session(name: "s", agentKind: .antigravity)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: "https://github.com/o/r/issues/7", provider: .github, codeProvider: nil)
        #expect(prompt.contains("gh issue view https://github.com/o/r/issues/7 --comments"))
    }

    @Test func jiraTicketFallsBackToAcliNotMCP() async {
        // Phase A has no MCP bridge for Antigravity — the Jira branch must
        // instruct `acli`, never a `jira_*` MCP tool.
        let session = Session(name: "s", agentKind: .antigravity)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: "https://x.atlassian.net/browse/ABC-123", provider: .jira, codeProvider: nil)
        #expect(prompt.contains("acli jira workitem view ABC-123"))
        #expect(prompt.contains("jira_get_issue") == false)
        #expect(prompt.lowercased().contains("mcp") == false)
    }

    // MARK: - launchCommand (handoff)

    @Test func launchCommandMaterializesPromptWith0600AndDashP() async throws {
        let sid = UUID()
        let cmd = try await launcher.launchCommand(
            sessionID: sid, worktreePath: "/wt/crow", prompt: "hello world", binary: "/bin/agy")

        // Shape: cd '<wt>' && '<binary>' -p "$(cat '<tmp>')" — all paths quoted.
        #expect(cmd.hasPrefix("cd '/wt/crow' && '/bin/agy' -p \"$(cat '"))
        #expect(cmd.hasSuffix("')\"\n"))

        // The temp prompt file exists, holds the prompt, and is owner-only 0600.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-antigravity-\(sid.uuidString)-prompt.md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try String(contentsOf: tmp, encoding: .utf8) == "hello world")
        let perms = try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func launchCommandQuotesWorktreeWithSpaces() async throws {
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(), worktreePath: "/Users/x/My Projects/wt",
            prompt: "p", binary: "/bin/agy")
        #expect(cmd.hasPrefix("cd '/Users/x/My Projects/wt' && "))
    }
}
