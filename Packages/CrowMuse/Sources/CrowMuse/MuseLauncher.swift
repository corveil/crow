import Foundation
import CrowCore

/// Generates initial prompts for Muse Code sessions and materializes them for
/// the agent-handoff path. Mirrors `GrokLauncher` / `AntigravityLauncher` —
/// plan-first preamble, workspace table, ticket-fetch instructions — with
/// **no** Claude slash commands and **no** `jira` MCP routing.
///
/// Phase A ships no MCP config writer for Muse (deferred — file-based
/// `mcp_servers` in `~/.config/muse/settings.json` is a follow-up), so the
/// Jira branch instructs `acli` directly, matching Codex/OpenCode/Grok/Antigravity.
public actor MuseLauncher {
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
                    lines.append("Fetch this work item with `acli jira workitem view \(key) --fields summary,status,description,comment`.")
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
    /// agent-handoff path (`crow handoff-agent --agent muse`). Runs the prompt
    /// headlessly, then chains into `resume` so the session stays resident
    /// with a fresh terminal stdin (see `MuseLaunchArgs`).
    ///
    /// `binary` is the resolved `muse` path — the caller passes
    /// `MuseAgent.findBinary()`, which is override-aware. `muse` is a
    /// collision-prone token (Muse Sequencer), so we must **not** re-resolve
    /// it here with a bare PATH walk.
    ///
    /// `trustWorkspace` is the per-launch `--trust-workspace` seed. Review
    /// handoffs must pass `false` so a stripped clone is not immediately
    /// re-trusted (skills/rules under `.claude/` / `.codex/` load after
    /// workspace trust even though `.muse/` + `.agents/` were stripped).
    public func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String,
        binary: String = "muse",
        trustWorkspace: Bool
    ) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let promptPath = tmpDir.appendingPathComponent("crow-muse-\(sessionID.uuidString)-prompt.md")
        try prompt.write(to: promptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: promptPath.path)
        let inner = MuseLaunchArgs.firstLaunchChainedCommand(
            binary: binary,
            promptPath: promptPath.path,
            autoPermissionMode: false,
            trustWorkspace: trustWorkspace
        ).trimmingCharacters(in: .newlines)
        return "cd \(ShellLaunchArgs.shellQuote(worktreePath)) && { \(inner); }\n"
    }
}
