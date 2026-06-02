import Foundation

/// Helpers for building the argument string appended to a `claude` shell invocation.
///
/// Centralized so worker-session launches, the Manager tab, and crow-CLI-spawned
/// terminals all produce consistent flags — and so the logic is independently testable.
public enum ClaudeLaunchArgs {
    /// POSIX single-quote escape for safe interpolation into a shell command line.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Flags to append after the `claude` binary path.
    ///
    /// Returns a string beginning with a leading space — e.g.
    /// `" --permission-mode auto --rc --name 'Manager'"` — or an empty string
    /// when neither option is enabled. The `--name` flag makes the session show
    /// up with a recognizable label in claude.ai's Remote Control panel.
    ///
    /// - Parameters:
    ///   - remoteControl: Append `--rc` (and `--name …` if `sessionName` is provided).
    ///   - sessionName: Optional label for the remote-control panel.
    ///   - autoPermissionMode: Append `--permission-mode auto`. Used for the Manager
    ///     terminal so orchestration commands (`crow`, `gh`, `git`) can run without
    ///     per-call approval. Requires a supported Claude Code plan and provider.
    public static func argsSuffix(
        remoteControl: Bool,
        sessionName: String?,
        autoPermissionMode: Bool = false
    ) -> String {
        var s = ""
        if autoPermissionMode {
            s += " --permission-mode auto"
        }
        if remoteControl {
            s += " --rc"
            if let name = sessionName, !name.isEmpty {
                s += " --name \(shellQuote(name))"
            }
        }
        return s
    }
}
