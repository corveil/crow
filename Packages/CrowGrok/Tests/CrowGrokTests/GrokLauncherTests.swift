import Foundation
import Testing
@testable import CrowGrok
@testable import CrowCore

@Suite("GrokLauncher")
struct GrokLauncherTests {
    private let launcher = GrokLauncher()

    private func worktree(_ repo: String = "crow", branch: String = "feature/x") -> SessionWorktree {
        SessionWorktree(
            sessionID: UUID(),
            repoName: repo,
            repoPath: "/repos/\(repo)",
            worktreePath: "/wt/\(repo)",
            branch: branch)
    }

    @Test func promptIncludesPlanPreambleAndWorkspaceTable() async {
        let session = Session(name: "s", agentKind: .grok)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: nil, provider: nil, codeProvider: nil)
        #expect(prompt.contains("sketch a brief plan"))
        #expect(prompt.contains("# Workspace Context"))
        #expect(prompt.contains("| crow | /wt/crow | feature/x | |"))
    }

    @Test func githubTicketUsesGhIssueView() async {
        let session = Session(name: "s", agentKind: .grok)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: "https://github.com/o/r/issues/7", provider: .github, codeProvider: nil)
        #expect(prompt.contains("gh issue view https://github.com/o/r/issues/7 --comments"))
    }

    @Test func jiraTicketFallsBackToAcliNotMCP() async {
        let session = Session(name: "s", agentKind: .grok)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: "https://x.atlassian.net/browse/ABC-123", provider: .jira, codeProvider: nil)
        #expect(prompt.contains("acli jira workitem view ABC-123"))
        #expect(prompt.contains("jira_get_issue") == false)
        #expect(prompt.lowercased().contains("mcp") == false)
    }

    @Test func workSeedMaterializesPromptWith0600AndInteractiveEval() async throws {
        let sid = UUID()
        let cmd = try await launcher.launchCommand(
            sessionID: sid, worktreePath: "/wt/crow", prompt: "hello world",
            binary: "/bin/grok", seedInteractively: true)

        #expect(cmd.hasPrefix("cd '/wt/crow' && "))
        #expect(cmd.contains("_CROW_P=$(< "))
        #expect(cmd.contains("eval \"'/bin/grok' -- "))
        #expect(!cmd.contains("--prompt-file"))
        #expect(!cmd.contains(" -c"))
        #expect(!cmd.contains("{ "))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-grok-\(sid.uuidString)-prompt.md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try String(contentsOf: tmp, encoding: .utf8) == "hello world")
        let perms = try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func workSeedQuotesWorktreeWithSpaces() async throws {
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(), worktreePath: "/Users/x/My Projects/wt",
            prompt: "p", binary: "/bin/grok", seedInteractively: true)
        #expect(cmd.hasPrefix("cd '/Users/x/My Projects/wt' && "))
    }

    @Test func unattendedSeedKeepsHeadlessThenContinue() async throws {
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(), worktreePath: "/wt/crow", prompt: "p",
            binary: "/bin/grok", seedInteractively: false)
        #expect(cmd.hasPrefix("cd '/wt/crow' && { "))
        #expect(cmd.contains("'/bin/grok' --prompt-file "))
        #expect(cmd.contains("'/bin/grok' -c"))
        #expect(!cmd.contains("_CROW_P="))
    }

    @Test func oversizedWorkSeedFallsBackToHeadlessChain() async throws {
        let huge = String(repeating: "a", count: GrokLaunchArgs.argvPromptByteLimit + 1)
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(), worktreePath: "/wt/crow", prompt: huge,
            binary: "/bin/grok", seedInteractively: true)
        #expect(cmd.contains("--prompt-file"))
        #expect(cmd.contains(" -c"))
        #expect(!cmd.contains("_CROW_P="))
    }
}
