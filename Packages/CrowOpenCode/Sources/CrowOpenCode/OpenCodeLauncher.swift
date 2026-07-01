import Foundation
import CrowCore

/// Generates initial prompts for OpenCode sessions. Mirrors the shape of
/// `CursorLauncher` — plan-first preamble, workspace table, ticket info —
/// without Claude-specific slash commands.
///
/// Phase MVP launches `opencode` bare for `.work` (the user types into the
/// TUI) and uses run-then-continue for unattended `.job`/`.review`
/// via `OpenCodeAgent.autoLaunchCommand`, so this type isn't wired into the
/// auto-launch path yet. It's the parity placeholder a follow-up will use
/// for an OpenCode-flavored `crow-workspace` skill.
public actor OpenCodeLauncher {
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
    /// prompt headlessly, then chains into `--continue` so the session stays
    /// resident with a fresh terminal stdin (#547).
    public func launchCommand(sessionID: UUID, worktreePath: String, prompt: String) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
        let promptPath = tmpDir.appendingPathComponent("crow-opencode-\(sessionID.uuidString)-prompt.md")
        try prompt.write(to: promptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: promptPath.path)
        let binary = ShellEnvironment.shared.findExecutable("opencode") ?? "opencode"
        let inner = OpenCodeLaunchArgs.firstLaunchChainedCommand(
            binary: binary,
            promptPath: promptPath.path,
            autoPermissionMode: false,
            tuiSupportsAuto: false,
            runHelpText: ""
        ).trimmingCharacters(in: .newlines)
        return "cd \(Self.shellEscape(worktreePath)) && { \(inner); }\n"
    }

    private static func shellEscape(_ str: String) -> String {
        let escaped = str.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
