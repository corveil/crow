import Foundation
import Testing
@testable import CrowMuse
@testable import CrowCore

@Suite("MuseLauncher")
struct MuseLauncherTests {
    private let launcher = MuseLauncher()

    private func worktree(_ repo: String = "crow", branch: String = "feature/x") -> SessionWorktree {
        SessionWorktree(
            sessionID: UUID(),
            repoName: repo,
            repoPath: "/repos/\(repo)",
            worktreePath: "/wt/\(repo)",
            branch: branch)
    }

    @Test func promptIncludesPlanPreambleAndWorkspaceTable() async {
        let session = Session(name: "s", agentKind: .muse)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: nil, provider: nil, codeProvider: nil)
        #expect(prompt.contains("sketch a brief plan"))
        #expect(prompt.contains("# Workspace Context"))
        #expect(prompt.contains("| crow | /wt/crow | feature/x | |"))
    }

    @Test func githubTicketUsesGhIssueView() async {
        let session = Session(name: "s", agentKind: .muse)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: "https://github.com/o/r/issues/7", provider: .github, codeProvider: nil)
        #expect(prompt.contains("gh issue view https://github.com/o/r/issues/7 --comments"))
    }

    @Test func jiraTicketFallsBackToAcliNotMCP() async {
        let session = Session(name: "s", agentKind: .muse)
        let prompt = await launcher.generatePrompt(
            session: session, worktrees: [worktree()],
            ticketURL: "https://x.atlassian.net/browse/ABC-123", provider: .jira, codeProvider: nil)
        #expect(prompt.contains("acli jira workitem view ABC-123"))
        #expect(prompt.contains("jira_get_issue") == false)
        #expect(prompt.lowercased().contains("mcp") == false)
    }

    @Test func launchCommandMaterializesPromptWith0600AndExec() async throws {
        let sid = UUID()
        let cmd = try await launcher.launchCommand(
            sessionID: sid, worktreePath: "/wt/crow", prompt: "hello world",
            binary: "/bin/muse", trustWorkspace: true)

        #expect(cmd.hasPrefix("cd '/wt/crow' && { "))
        #expect(cmd.contains("'/bin/muse' exec"))
        #expect(cmd.contains("--prompt-file"))
        #expect(cmd.contains(" resume"))
        #expect(cmd.contains("--trust-workspace"))
        #expect(!cmd.contains("--yolo"))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-muse-\(sid.uuidString)-prompt.md")
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(try String(contentsOf: tmp, encoding: .utf8) == "hello world")
        let perms = try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func launchCommandQuotesWorktreeWithSpaces() async throws {
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(), worktreePath: "/Users/x/My Projects/wt",
            prompt: "p", binary: "/bin/muse", trustWorkspace: true)
        #expect(cmd.hasPrefix("cd '/Users/x/My Projects/wt' && "))
    }

    @Test func launchCommandWithholdsTrustWhenAsked() async throws {
        let cmd = try await launcher.launchCommand(
            sessionID: UUID(), worktreePath: "/wt/crow", prompt: "p",
            binary: "/bin/muse", trustWorkspace: false)
        #expect(!cmd.contains("--trust-workspace"))
        #expect(cmd.contains(" exec"))
        #expect(cmd.contains(" resume"))
        #expect(!cmd.contains("--yolo"))
    }
}
