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
    public static func evalPromptLaunch(prefix: String, promptPath: String) -> String {
        let quotedPath = shellQuote(promptPath)
        return "_CROW_P=$(< \(quotedPath)); eval \"\(prefix) $(printf '%q' \"$_CROW_P\")\"\n"
    }
}
