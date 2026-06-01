import Foundation
import CrowCore

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

    /// Shell prefix that applies (or clears) the AI-gateway env vars on the
    /// `claude` launch line (CROW-402). Placed immediately before the `claude`
    /// binary path so it overrides any value exported by the user's `~/.zshrc`
    /// for this invocation. Re-runs are covered separately by the
    /// `settings.local.json` `env` block, so this is the initial-launch override
    /// and the load-bearing no-leak guard.
    ///
    /// Uses `export … &&` (not bare `VAR=val` command-prefix assignments) so it
    /// composes correctly in front of the OTEL `export … &&` prefix that
    /// `ClaudeCodeAgent.autoLaunchCommand` bakes into the launch string — a bare
    /// `VAR=val` prefix would bind only to that following `export` builtin, not to
    /// the eventual `claude` process.
    ///
    /// - `resolved` present → `export ANTHROPIC_BASE_URL='…' ANTHROPIC_CUSTOM_HEADERS='…' && `
    /// - `resolved` nil → `unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && `
    ///   so a no-gateway workspace doesn't inherit a sibling's or `~/.zshrc`'s gateway.
    /// - multi-header → the header value has an embedded newline and can't go on
    ///   the line (a pasted newline would submit the command early), so it's
    ///   carried solely by `settings.local.json`. We still `unset ANTHROPIC_CUSTOM_HEADERS`
    ///   before exporting `ANTHROPIC_BASE_URL`, so the gateway's baseURL is never
    ///   paired with a stale `~/.zshrc`-inherited header value.
    public static func gatewayEnvPrefix(_ resolved: GatewayResolver.Resolved?) -> String {
        guard let resolved else {
            return "unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && "
        }
        let baseAssignment = "export ANTHROPIC_BASE_URL=\(shellQuote(resolved.baseURL))"
        if resolved.customHeaders.contains("\n") {
            return "unset ANTHROPIC_CUSTOM_HEADERS && " + baseAssignment + " && "
        }
        return baseAssignment + " ANTHROPIC_CUSTOM_HEADERS=\(shellQuote(resolved.customHeaders)) && "
    }
}
