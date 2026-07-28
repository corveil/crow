import Foundation
import CrowCore

/// Generates initial prompts for Grok Build sessions and materializes them for
/// launch. Mirrors the shape of `CodexLauncher` / `OpenCodeLauncher` — plan-
/// first preamble, workspace table, ticket-fetch instructions — without any
/// Claude-specific slash commands.
///
/// The auto-launch path (`GrokAgent.autoLaunchCommand`) builds its own
/// run-then-continue command from the pre-written prompt file, so this type is
/// the parity placeholder a follow-up will use for a Grok-flavored
/// `crow-workspace` skill (Jira MCP bridge is deferred to Phase B — the ticket
/// fetch falls back to `acli`, like Codex).
public actor GrokLauncher {
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
                if let key = Validation.jiraKey(from: url) {
                    lines.append("```bash")
                    lines.append("acli jira workitem view \(key) --fields summary,status,description,comment")
                    lines.append("```")
                } else {
                    lines.append("URL: \(url)")
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

    /// Write `prompt` to a temp file and return the launch command. Runs the
    /// prompt headlessly, then chains into `-c` so the session stays resident
    /// with a fresh terminal stdin (see `GrokLaunchArgs`).
    ///
    /// `binary` is the resolved `grok` path — the caller passes
    /// `GrokAgent.findBinary()`, which is override-aware (`defaults.binaries.grok`)
    /// + fallback-candidate-aware. `grok` is a collision-prone token (community
    /// `superagent-ai/grok-cli`), so we must **not** re-resolve it here with a bare
    /// PATH walk (`ShellEnvironment.findExecutable`): that would ignore the pin and
    /// launch the wrong `grok` on the handoff path — the same reason
    /// `CursorLauncher.launchCommand` receives `CursorAgent.findBinary()` (#861
    /// review round 8). Defaults to `"grok"` only as a last resort.
    public func launchCommand(sessionID: UUID, worktreePath: String, prompt: String, binary: String = "grok") throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let promptPath = tmpDir.appendingPathComponent("crow-grok-\(sessionID.uuidString)-prompt.md")
        try prompt.write(to: promptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: promptPath.path)
        let inner = GrokLaunchArgs.firstLaunchChainedCommand(
            binary: binary,
            promptPath: promptPath.path,
            autoPermissionMode: false
        ).trimmingCharacters(in: .newlines)
        return "cd \(Self.shellEscape(worktreePath)) && { \(inner); }\n"
    }

    private static func shellEscape(_ str: String) -> String {
        let escaped = str.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
