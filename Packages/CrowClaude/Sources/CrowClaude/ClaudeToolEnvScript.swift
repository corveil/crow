import Foundation
import CrowCore

/// Keeps the AI-gateway key out of the environment of an agent's Bash tool
/// commands (CROW-1484).
///
/// Claude Code needs `ANTHROPIC_CUSTOM_HEADERS` in its own environment to reach
/// the gateway, and the commands it runs inherit that environment. So a plain
/// `env | grep ANTHROPIC` in a tool call prints the key into the transcript,
/// which log sync uploads and the gateway can store in its request logs.
///
/// Claude Code reads the file named by `CLAUDE_ENV_FILE` and runs it ahead of
/// every Bash tool command; a missing file is skipped without error. Crow points
/// `CLAUDE_ENV_FILE` (in the settings `env` block it already writes) at this
/// static script, which unsets the variable in the command's shell. Claude
/// Code's own process keeps it, so requests still carry the key.
///
/// Probed on Claude Code 2.1.329: a Bash tool call sees `ANTHROPIC_CUSTOM_HEADERS`
/// without the script and doesn't with it, while the session keeps reaching the
/// gateway.
///
/// What this does **not** cover, by design or by limit:
/// - It is a guard against accidental printing, not a boundary. The agent runs
///   as the same user, so it can still read `.claude/settings.local.json`, or
///   the `claude` process's environment (`ps eww`), on purpose.
/// - Hooks and MCP servers that Claude Code spawns directly don't run the
///   script, so they still inherit the variable.
/// - Claude Code's built-in alternative, `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`,
///   strips `ANTHROPIC_CUSTOM_HEADERS` from every subprocess but also forces the
///   permission mode to `default` (as of 2.1.329), which would break the Manager's
///   and unattended sessions' `--permission-mode auto`. Crow doesn't set it.
/// - A `CLAUDE_ENV_FILE` the user exported in their shell is replaced for
///   gateway-routed sessions, because the settings `env` block outranks it.
public enum ClaudeToolEnvScript {
    /// The Claude Code variable that names the script.
    public static let envKey = "CLAUDE_ENV_FILE"

    /// The script's file name. ``isCrowScript(_:)`` matches on it, so clearing a
    /// gateway removes Crow's entry wherever the script lived, and nothing else.
    ///
    /// Crow keeps it beside `store.json` in its app-support dir
    /// (`~/Library/Application Support/crow/` on macOS, `~/.local/share/crow/` on
    /// Linux): outside every worktree, so it never shows up in a repo's
    /// `git status` and a review clone can't supply its own.
    public static let fileName = "crow-claude-tool-env.sh"

    /// The script body. Static, and holds no secret: every gateway-routed
    /// session shares one copy.
    public static let contents = """
        # Written by Crow (CROW-1484). Do not edit; Crow rewrites it.
        # Claude Code runs this file before every Bash tool command (CLAUDE_ENV_FILE),
        # so the commands an agent runs don't inherit the AI-gateway key.
        # Claude Code's own process keeps ANTHROPIC_CUSTOM_HEADERS.
        unset ANTHROPIC_CUSTOM_HEADERS

        """

    /// Whether a `CLAUDE_ENV_FILE` value is one Crow wrote.
    public static func isCrowScript(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == fileName
    }

    /// Write the script at `path` unless it already holds ``contents``. Returns
    /// whether the file now holds them.
    @discardableResult
    public static func ensure(at path: String) -> Bool {
        let wanted = Data(contents.utf8)
        if FileManager.default.contents(atPath: path) == wanted { return true }
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try wanted.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            CrowLog.info("[ClaudeToolEnvScript] Failed to write \(path): \(error.localizedDescription)")
            return false
        }
    }
}
