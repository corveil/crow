import Foundation
import CrowCore

/// Generates initial prompts for Antigravity (`agy`) sessions and materializes
/// them for the agent-handoff path. Mirrors `CursorLauncher` / `GrokLauncher`
/// — plan-first preamble, workspace table, ticket info — with **no** Claude
/// slash commands. The Jira arm prefers the `jira` MCP
/// (`AntigravityMCPConfigWriter` mirrors it from `~/.claude.json` into
/// `mcp_config.json` at launch) and keeps `acli` only as the no-MCP fallback.
public actor AntigravityLauncher {
    public init() {}

    public func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?,
        codeProvider: Provider? = nil,
        jiraMCPAvailable: Bool = false
    ) -> String {
        var lines: [String] = []
        lines.append("Before editing anything, sketch a brief plan covering:")
        lines.append("- The files you'll touch and why")
        lines.append("- Any migrations or cascading updates")
        lines.append("- How you'll verify the change")
        lines.append("Then proceed once the approach is clear.")
        lines.append("")
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

            switch provider {
            case .github:
                lines.append("```bash")
                lines.append("gh issue view \(url) --comments")
                lines.append("```")
            case .gitlab:
                lines.append("```bash")
                lines.append("glab issue view \(url) --comments")
                lines.append("```")
            case .jira:
                if let key = Validation.jiraKey(from: url) {
                    if jiraMCPAvailable {
                        // Prefer the mirrored `jira` MCP (`AntigravityMCPConfigWriter`
                        // writes `mcpServers.jira` at launch), with `acli` as the
                        // fallback for the no-bridge case.
                        lines.append("Fetch this work item via the **`jira` MCP server** (bridged into this session): call `jira_get_issue` for key `\(key)`, and use the `jira_*` MCP tools for any Jira read/create/transition/comment. If the `jira` MCP isn't available, fall back to `acli jira workitem view \(key) --fields summary,status,description,comment`.")
                    } else {
                        lines.append("Fetch this work item with `acli jira workitem view \(key) --fields summary,status,description,comment`.")
                    }
                } else if jiraMCPAvailable {
                    lines.append("URL: \(url) — fetch it via the `jira` MCP server (`jira_get_issue`), or `acli` if the MCP isn't available.")
                } else {
                    lines.append("URL: \(url) — fetch it with `acli jira workitem view <KEY> --fields summary,status,description,comment`.")
                }
            case nil:
                lines.append("URL: \(url)")
            }
        }

        lines.append("")
        lines.append("## Instructions")
        lines.append("1. Study the ticket thoroughly")
        lines.append("2. Create an implementation plan")

        return lines.joined(separator: "\n")
    }

    /// Write `prompt` to a temp file and return the launch command used by the
    /// agent-handoff path (`crow handoff-agent --agent antigravity`) to start
    /// `agy` on that prompt instead of a bare TUI.
    ///
    /// `binary` is the resolved `agy` path (`AntigravityAgent.findBinary()`), so
    /// a `defaults.binaries.antigravity` override is honored and a narrow PATH
    /// still launches.
    ///
    /// Like `CursorLauncher.launchCommand`, this one-shot handoff command feeds
    /// the prompt only (`-p`); `AntigravityAgent.autoLaunchCommand` owns the
    /// (re)launch/resume path that follows a handoff.
    public func launchCommand(sessionID: UUID, worktreePath: String, prompt: String, binary: String = "agy") throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let promptPath = tmpDir.appendingPathComponent("crow-antigravity-\(sessionID.uuidString)-prompt.md")
        try prompt.write(to: promptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: promptPath.path)
        return "cd \(AntigravityLaunchArgs.shellQuote(worktreePath)) && "
            + ShellLaunchArgs.evalPromptLaunch(
                prefix: "\(AntigravityLaunchArgs.shellQuote(binary)) -p",
                promptPath: promptPath.path).trimmingCharacters(in: .newlines) + "\n"
    }
}
