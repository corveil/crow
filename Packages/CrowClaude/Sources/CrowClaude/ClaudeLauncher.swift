import Foundation
import CrowCore

/// Generates prompts and launches Claude Code in terminal sessions.
public actor ClaudeLauncher {
    public init() {}

    /// Generate the initial prompt for Claude Code (same template as /workspace skill).
    /// - Parameters:
    ///   - provider: the **task** provider (where the ticket lives) — drives the
    ///     "study the ticket" fetch command.
    ///   - codeProvider: the **code** provider (where the PR lives) — drives the
    ///     "open a PR/MR" step. Defaults to `provider` when `nil`. For a Jira-task
    ///     + GitHub-code session these differ: the ticket is fetched via the
    ///     Atlassian MCP server while the PR is still opened with `gh` (ADR 0005
    ///     cross-backend pairing; CROW-522 migrated Jira off `acli`).
    public func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?,
        codeProvider: Provider? = nil,
        customInstructions: String? = nil
    ) -> String {
        // Plan mode is set by the `--permission-mode plan` flag in setup.sh's
        // launch_claude(); do not prepend `/plan` here — that token is parsed
        // as a slash command by the receiving session. See issue #313.
        var lines: [String] = []
        lines.append("# Workspace Context")
        lines.append("")
        lines.append("| Repository | Path | Branch | Description |")
        lines.append("|------------|------|--------|-------------|")

        for wt in worktrees {
            lines.append("| \(wt.repoName) | \(wt.worktreePath) | \(wt.branch) | |")
        }

        if let url = ticketURL {
            lines.append("")
            lines.append("## Ticket")
            lines.append("")
            lines.append("IMPORTANT: All gh/glab commands MUST use dangerouslyDisableSandbox: true. They will fail with TLS certificate errors otherwise. Do NOT attempt sandboxed first.")

            switch provider {
            case .github:
                lines.append("")
                lines.append("```bash")
                lines.append("gh issue view \(url) --comments")
                lines.append("```")
            case .gitlab:
                lines.append("")
                lines.append("```bash")
                lines.append("glab issue view \(url) --comments")
                lines.append("```")
            case .jira:
                lines.append("")
                if let key = Validation.jiraKey(from: url) {
                    lines.append("Fetch this work item via the **Atlassian MCP server** (pre-configured for this session): resolve your cloudId with `getAccessibleAtlassianResources`, then call `getJiraIssue` for key `\(key)`. Use the MCP tools — not `acli` — for any Jira create/assign/transition/comment as well.")
                } else {
                    lines.append("URL: \(url) — fetch it via the Atlassian MCP server (`getJiraIssue`).")
                }
            case .corveil, nil:
                lines.append("URL: \(url)")
            }
        }

        lines.append("")
        lines.append("## Instructions")
        lines.append("1. Study the ticket thoroughly — use dangerouslyDisableSandbox: true for ALL gh/glab commands")
        lines.append("2. Create an implementation plan")
        lines.append("3. Implement the plan")
        lines.append("4. Commit the changes with a descriptive message")
        lines.append("5. Push the branch to origin")

        let ticketIsPR = ticketURL.map(Self.isPullRequestURL) ?? false
        if ticketIsPR {
            lines.append("6. The ticket is itself a pull/merge request — pushing the branch updates it; do not open a new one")
        } else {
            appendOpenPRStep(
                to: &lines,
                provider: codeProvider ?? provider,
                ticketNumber: session.ticketNumber,
                hasTicket: ticketURL != nil
            )
        }

        if let instructions = customInstructions,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("## Custom Instructions")
            lines.append("")
            lines.append(instructions)
        }

        return lines.joined(separator: "\n")
    }

    /// Append the final "open a PR/MR" instruction, branching on provider.
    private func appendOpenPRStep(
        to lines: inout [String],
        provider: Provider?,
        ticketNumber: Int?,
        hasTicket: Bool
    ) {
        let suffix = hasTicket ? " linked to the ticket" : ""
        switch provider {
        case .github:
            lines.append("6. Open a pull request\(suffix):")
            lines.append("")
            lines.append("```bash")
            if let n = ticketNumber {
                lines.append("gh pr create --title \"<summary>\" --body \"Closes #\(n)\" --base main")
            } else {
                lines.append("gh pr create --fill --base main")
            }
            lines.append("```")
        case .gitlab:
            lines.append("6. Open a merge request\(suffix):")
            lines.append("")
            lines.append("```bash")
            if let n = ticketNumber {
                lines.append("glab mr create --title \"<summary>\" --description \"Closes #\(n)\" --target-branch main")
            } else {
                lines.append("glab mr create --fill --target-branch main")
            }
            lines.append("```")
        case .jira, .corveil, nil:
            // Task-only code providers shouldn't reach here — a Jira-tasked
            // session resolves its `codeProvider` to GitHub/GitLab. Fall back to
            // a generic instruction if it does.
            lines.append("6. Open a pull request\(suffix)")
        }
    }

    /// True when the URL points at a pull/merge request rather than an issue.
    private static func isPullRequestURL(_ url: String) -> Bool {
        url.contains("/pull/") || url.contains("/merge_requests/")
    }


    /// Write prompt to temp file and return the launch command.
    public func launchCommand(sessionID: UUID, worktreePath: String, prompt: String) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let promptPath = tmpDir.appendingPathComponent("rmide-\(sessionID.uuidString)-prompt.md")
        try prompt.write(to: promptPath, atomically: true, encoding: .utf8)
        // Restrict prompt file to owner-only access
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: promptPath.path)
        return "cd \(Self.shellEscape(worktreePath)) && claude \"$(cat \(Self.shellEscape(promptPath.path)))\"\n"
    }

    /// Escape a string for safe inclusion in a shell command by wrapping in single quotes.
    private static func shellEscape(_ str: String) -> String {
        // Replace each single quote with: end-quote, escaped-quote, start-quote
        let escaped = str.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
