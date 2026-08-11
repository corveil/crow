import Foundation

/// Helpers for building shell launch commands Crow pastes into managed tmux
/// panes. Centralized so every `CodingAgent` shares one quoting strategy.
public enum ShellLaunchArgs {
    /// POSIX single-quote escape for paths interpolated into shell commands.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Bash statements that read `promptPath`, then `eval` a command built from
    /// `prefix` (the shell-quoted agent binary plus flags) with the prompt file
    /// contents as the final argv.
    ///
    /// Avoid `"$(cat path)"`, which breaks when the file contains `"` (#957).
    /// macOS bash's `printf %q` emits backslash escapes that must be re-parsed
    /// via `eval` (unlike GNU bash's `$'…'` form). Crow pastes this into the
    /// user's interactive shell (zsh/bash via `crow-shell-wrapper`).
    ///
    /// `endOfOptions` emits a literal `--` before the prompt, so a prompt whose
    /// first character is `-` reaches the binary as an operand instead of being
    /// parsed as a flag. Quoting does **not** cover this: `printf %q` protects the
    /// string from the *shell*, but a leading hyphen is not shell-special and
    /// survives into argv, where an option parser claims it (CROW-968).
    ///
    /// It is **opt-in per agent, not a global default**, because `--` is a
    /// convention rather than a guarantee — this helper is shared by Claude,
    /// Codex, OpenCode and Antigravity, and a parser that treats a bare `--` as a
    /// literal prompt word would silently corrupt every launch. Enable it only for
    /// a CLI whose behaviour has been checked. Verified so far:
    ///
    /// - **Cursor** (`agent`, commander): `agent --list-models --bogus` →
    ///   `error: unknown option '--bogus'`; `agent --list-models -- --bogus`
    ///   parses clean. Enabled at both Cursor call sites.
    public static func evalPromptLaunch(
        prefix: String,
        promptPath: String,
        endOfOptions: Bool = false
    ) -> String {
        let quotedPath = shellQuote(promptPath)
        let separator = endOfOptions ? "-- " : ""
        return "_CROW_P=$(< \(quotedPath)); eval \"\(prefix) \(separator)$(printf '%q' \"$_CROW_P\")\"\n"
    }
}
