import Foundation
import Testing
@testable import CrowClaude
@testable import CrowCore

// MARK: - generatePrompt()

@Test func generatePromptWithGitHubProvider() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session", ticketNumber: 42)
    let worktree = SessionWorktree(
        sessionID: session.id,
        repoName: "my-repo",
        repoPath: "/repos/my-repo",
        worktreePath: "/worktrees/my-repo-42-feature",
        branch: "feature/42-cool"
    )

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [worktree],
        ticketURL: "https://github.com/org/repo/issues/42",
        provider: .github
    )

    #expect(prompt.hasPrefix("# Workspace Context"))
    #expect(prompt.contains("| my-repo |"))
    #expect(prompt.contains("feature/42-cool"))
    #expect(prompt.contains("gh issue view"))
    #expect(prompt.contains("dangerouslyDisableSandbox"))
    // Completion instructions: commit / push / open PR with ticket linkage
    #expect(prompt.contains("Commit the changes"))
    #expect(prompt.contains("Push the branch"))
    #expect(prompt.contains("gh pr create"))
    #expect(prompt.contains("Closes #42"))
    #expect(!prompt.contains("glab mr create"))
}

@Test func generatePromptWithGitLabProvider() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session", ticketNumber: 10)

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: "https://gitlab.com/org/repo/-/issues/10",
        provider: .gitlab
    )

    #expect(prompt.contains("glab issue view"))
    #expect(prompt.contains("dangerouslyDisableSandbox"))
    #expect(prompt.contains("glab mr create"))
    #expect(prompt.contains("Closes #10"))
    #expect(prompt.contains("merge request"))
    #expect(!prompt.contains("gh pr create"))
}

@Test func generatePromptWithJiraTaskAndGitHubCode() async {
    // Cross-backend session (ADR 0005): Jira task + GitHub code. The ticket is
    // fetched with `acli`, but the PR step still uses `gh`.
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session", ticketNumber: 7)

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: "https://acme.atlassian.net/browse/PROJ-7",
        provider: .jira,
        codeProvider: .github
    )

    // Ticket step routes through acli with the extracted key.
    #expect(prompt.contains("acli jira workitem view PROJ-7"))
    #expect(!prompt.contains("gh issue view"))
    // PR step routes through the code backend (GitHub).
    #expect(prompt.contains("gh pr create"))
    #expect(!prompt.contains("glab mr create"))
}

@Test func generatePromptWithNilProvider() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session")

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: "https://example.com/ticket/1",
        provider: nil
    )

    #expect(prompt.contains("URL: https://example.com/ticket/1"))
    #expect(!prompt.contains("gh issue"))
    #expect(!prompt.contains("glab issue"))
    // With an unknown provider, we must not emit a provider-specific CLI command
    #expect(!prompt.contains("gh pr create"))
    #expect(!prompt.contains("glab mr create"))
    #expect(prompt.contains("Open a pull request"))
}

@Test func generatePromptWithNoTicket() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session")
    let worktree = SessionWorktree(
        sessionID: session.id,
        repoName: "repo",
        repoPath: "/repos/repo",
        worktreePath: "/worktrees/repo-1-feat",
        branch: "feature/1-feat"
    )

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [worktree],
        ticketURL: nil,
        provider: nil
    )

    #expect(prompt.hasPrefix("# Workspace Context"))
    #expect(prompt.contains("| repo |"))
    #expect(!prompt.contains("## Ticket"))
    // Without a ticket, the PR step is still present (generic form)
    #expect(prompt.contains("Push the branch"))
    #expect(prompt.contains("Open a pull request"))
    #expect(!prompt.contains("Closes #"))
}

@Test func generatePromptWithEmptyWorktrees() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session")

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: nil,
        provider: nil
    )

    #expect(prompt.contains("| Repository | Path | Branch | Description |"))
    #expect(prompt.contains("## Instructions"))
}

@Test func generatePromptWhenTicketIsPullRequestGitHub() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session", ticketNumber: 77)

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: "https://github.com/org/repo/pull/77",
        provider: .github
    )

    // When the ticket is already a PR, we must not instruct the agent to open a new one
    #expect(!prompt.contains("gh pr create"))
    #expect(!prompt.contains("Closes #"))
    #expect(prompt.contains("Push the branch"))
    #expect(prompt.contains("pushing the branch updates it"))
}

@Test func generatePromptWhenTicketIsMergeRequestGitLab() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session", ticketNumber: 77)

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: "https://gitlab.com/org/repo/-/merge_requests/77",
        provider: .gitlab
    )

    #expect(!prompt.contains("glab mr create"))
    #expect(!prompt.contains("Closes #"))
    #expect(prompt.contains("pushing the branch updates it"))
}

@Test func generatePromptDoesNotStartWithPlanSlashCommand() async {
    // Plan mode is set via the `--permission-mode plan` flag in setup.sh,
    // not via a `/plan` slash-command prefix on the prompt body. See
    // issue #313 — a leading `/plan` is parsed as a slash command by the
    // receiving session and causes problems.
    let launcher = ClaudeLauncher()
    let prompt = await launcher.generatePrompt(
        session: Session(name: "regress"),
        worktrees: [],
        ticketURL: nil,
        provider: nil
    )
    #expect(!prompt.hasPrefix("/plan"))
    #expect(!prompt.contains("\n/plan\n"))
}

// MARK: - launchCommand()

@Test func launchCommandWritesTempFile() async throws {
    let launcher = ClaudeLauncher()
    let sessionID = UUID()
    let command = try await launcher.launchCommand(
        sessionID: sessionID,
        worktreePath: "/test/path",
        prompt: "test prompt"
    )

    #expect(command.contains("claude"))
    #expect(command.contains("cd"))

    // Verify temp file was created
    let tmpDir = FileManager.default.temporaryDirectory
    let promptPath = tmpDir.appendingPathComponent("rmide-\(sessionID.uuidString)-prompt.md")
    let content = try String(contentsOf: promptPath, encoding: .utf8)
    #expect(content == "test prompt")

    // Verify file permissions (owner-only read/write)
    let attrs = try FileManager.default.attributesOfItem(atPath: promptPath.path)
    let permissions = attrs[.posixPermissions] as? Int
    #expect(permissions == 0o600)

    // Clean up
    try? FileManager.default.removeItem(at: promptPath)
}

@Test func launchCommandEscapesSingleQuotes() async throws {
    let launcher = ClaudeLauncher()
    let command = try await launcher.launchCommand(
        sessionID: UUID(),
        worktreePath: "/path/with'quote",
        prompt: "test"
    )

    // The path should be shell-escaped with single-quote handling
    #expect(command.contains("'\\''"))
}

// MARK: - Custom instructions

@Test func generatePromptWithCustomInstructions() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session")

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: nil,
        provider: nil,
        customInstructions: "Always run npm test before committing"
    )

    #expect(prompt.contains("## Custom Instructions"))
    #expect(prompt.contains("Always run npm test before committing"))
}

@Test func generatePromptWithoutCustomInstructions() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session")

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: nil,
        provider: nil,
        customInstructions: nil
    )

    #expect(!prompt.contains("## Custom Instructions"))
}

@Test func generatePromptWithEmptyCustomInstructions() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "test-session")

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [],
        ticketURL: nil,
        provider: nil,
        customInstructions: "   \n  "
    )

    #expect(!prompt.contains("## Custom Instructions"))
}

// MARK: - Prompt structure

@Test func generatePromptMultipleWorktrees() async {
    let launcher = ClaudeLauncher()
    let session = Session(name: "multi-repo")
    let wt1 = SessionWorktree(
        sessionID: session.id,
        repoName: "frontend",
        repoPath: "/repos/frontend",
        worktreePath: "/wt/frontend-1-feat",
        branch: "feature/1-feat"
    )
    let wt2 = SessionWorktree(
        sessionID: session.id,
        repoName: "backend",
        repoPath: "/repos/backend",
        worktreePath: "/wt/backend-1-feat",
        branch: "feature/1-feat"
    )

    let prompt = await launcher.generatePrompt(
        session: session,
        worktrees: [wt1, wt2],
        ticketURL: nil,
        provider: nil
    )

    #expect(prompt.contains("| frontend |"))
    #expect(prompt.contains("| backend |"))
}
