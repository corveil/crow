import Foundation

/// Helpers for building the argument string appended to an `agent` (Cursor CLI)
/// invocation. Centralized so `CursorAgent`, the launcher, and tests share one
/// implementation of the flag choices — mirrors `ClaudeLaunchArgs` and
/// `OpenCodeLaunchArgs` (#829).
public enum CursorLaunchArgs {
    /// POSIX single-quote escape for safe interpolation into a shell command line.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Bounded auto-permission flags for unattended launches (`.job`, `.review`,
    /// the opt-in work coder view, and the Manager when its auto-permission
    /// toggle is on). Returns a leading-space suffix — e.g.
    /// `" --force --sandbox enabled --approve-mcps --trust"` — or `""` when
    /// auto-permission is off.
    ///
    /// **Bounded, not unbounded** (#829 scope corrections). Approval is turned
    /// off (`--force`) but the workspace **sandbox stays on** (`--sandbox
    /// enabled`): the analogue of Claude's `--permission-mode auto` and Codex's
    /// `-a never -s workspace-write`. We deliberately do **not**:
    ///
    /// - use bare `--force`/`--yolo` (approve *and* no sandbox) — that's the
    ///   unbounded posture, wrong as a default; or
    /// - reach for `--auto-review` — present in `--help` on this build but not in
    ///   the CLI parameter reference, so unverified/unstable, and a different
    ///   security posture (a server classifier decides what runs).
    ///
    /// `--approve-mcps` auto-approves configured MCP servers (e.g. the bridged
    /// `jira` MCP, see `CursorMCPConfigWriter`) so an unattended run doesn't
    /// block on the MCP-approval prompt. `--trust` seeds workspace trust so a
    /// fresh worktree's "trust this folder?" prompt can't block dispatch
    /// (the Cursor analogue of `ClaudeTrustSeeder`). Both are top-level options
    /// on the `agent` command (verified against `agent --help`, 2026.07.23), so
    /// they compose with the interactive TUI launch, not just headless `-p`.
    public static func autoPermissionSuffix(_ autoPermissionMode: Bool) -> String {
        guard autoPermissionMode else { return "" }
        return " --force --sandbox enabled --approve-mcps --trust"
    }
}
