import Foundation
import CrowCore

/// Generates initial prompts for Cursor sessions. Mirrors the shape of
/// `CodexLauncher` — plan-first preamble, workspace table, ticket info —
/// without Claude-specific slash commands or `dangerouslyDisableSandbox`
/// directives.
///
/// `generatePrompt` feeds `CursorAgent.generatePrompt`, and `launchCommand`
/// is used by the agent-handoff path (`crow handoff-agent --agent cursor`) to
/// materialize that prompt and start `agent` with it — so a handoff into
/// Cursor lands on a working session instead of a bare TUI (#829).
public actor CursorLauncher {
    public init() {}

    public func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?,
        codeProvider: Provider? = nil
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
                lines.append("")
                if let key = Validation.jiraKey(from: url) {
                    // Prefer the bridged `jira` MCP (CursorMCPConfigWriter mirrors
                    // it from ~/.claude.json and `--approve-mcps` auto-approves
                    // it), with `acli` as the fallback for the no-bridge case.
                    lines.append("Fetch this work item via the **`jira` MCP server** (bridged into this session): call `jira_get_issue` for key `\(key)`, and use the `jira_*` MCP tools for any Jira read/create/transition/comment. If the `jira` MCP isn't available, fall back to `acli jira workitem view \(key) --fields summary,status,description,comment`.")
                } else {
                    lines.append("URL: \(url) — fetch it via the `jira` MCP server (`jira_get_issue`), or `acli` if the MCP isn't available.")
                }
            case .corveil, nil:
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
    /// agent-handoff path (`crow handoff-agent --agent cursor`) to start
    /// `agent` on that prompt instead of a bare TUI (#829).
    ///
    /// `binary` is the resolved `agent` path (`CursorAgent.findBinary()`), so a
    /// `defaults.binaries.cursor` override is honored and a narrow PATH still
    /// launches — `agent` is a collision-prone token, so we don't hardcode it.
    ///
    /// This one-shot handoff command intentionally does **not** carry the
    /// auto-permission flags (`--force --approve-mcps`) — like
    /// `ClaudeLauncher.launchCommand`, it feeds the prompt only, and
    /// `CursorAgent.autoLaunchCommand` applies those on the (re)launch that
    /// follows. It carries the `--trust` workspace-trust seed
    /// (`CursorLaunchArgs.trustSuffix`) **only when `seedTrust` is true** — trust
    /// is orthogonal to auto-permission, and a first Cursor launch in a worktree
    /// another agent set up is fresh from Cursor's trust ledger, so it would
    /// otherwise block on the folder-trust dialog (CROW-890). `seedTrust` has
    /// **no default on purpose** (CROW-890 review, Yellow 2): a fail-open default
    /// is the one place this guard could silently regress, so every call site
    /// must state its intent. `CursorAgent` passes `sessionKind != .review`
    /// (attacker-controlled review clones are never auto-trusted, Red 1).
    public func launchCommand(sessionID: UUID, worktreePath: String, prompt: String, binary: String = "agent", seedTrust: Bool) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let promptPath = tmpDir.appendingPathComponent("crow-cursor-\(sessionID.uuidString)-prompt.md")
        try prompt.write(to: promptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: promptPath.path)
        let trust = seedTrust ? CursorLaunchArgs.trustSuffix : ""
        // `endOfOptions: true` — same commander parser as `CursorAgent`, so a
        // handoff note beginning with `-` would be read as a flag and abort the
        // launch (CROW-968). See `ShellLaunchArgs.evalPromptLaunch`.
        return "cd \(CursorLaunchArgs.shellQuote(worktreePath)) && "
            + ShellLaunchArgs.evalPromptLaunch(
                prefix: "\(CursorLaunchArgs.shellQuote(binary))\(trust)",
                promptPath: promptPath.path,
                endOfOptions: true).trimmingCharacters(in: .newlines) + "\n"
    }
}
