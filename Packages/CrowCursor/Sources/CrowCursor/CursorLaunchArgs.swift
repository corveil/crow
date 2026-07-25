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

    /// Auto-permission flags for unattended launches (`.job`, `.review`, the
    /// opt-in work coder view, and the Manager when its auto-permission toggle
    /// is on). Returns a leading-space suffix — e.g. `" --force --approve-mcps"`
    /// — or `""` when auto-permission is off.
    ///
    /// **Genuine parity with Claude's `--permission-mode auto`.** `--force`
    /// turns per-call approval off; `--approve-mcps` auto-approves configured
    /// MCP servers (e.g. the bridged `jira` MCP, see `CursorMCPConfigWriter`) so
    /// an unattended run doesn't block on the MCP-approval prompt. Claude's auto
    /// mode imposes no filesystem/network sandbox, so this now matches it exactly
    /// (the earlier "bounded" framing was a Cursor-only enhancement — see below).
    ///
    /// **`--sandbox enabled` is intentionally NOT set** (was `#829`, dropped in
    /// review). It blocks **network** by default ([Cursor 2.5](https://cursor.com/changelog/2-5)),
    /// which the sandbox enforces at the syscall level — `--force` (a tool-approval
    /// bypass) can't lift it. Every unattended Crow flow needs network the sandbox
    /// would block: `.review` posts its verdict via `gh pr review`, `.job` runs
    /// `git push`/`gh pr create`, and the **Manager** talks to `crow` over a Unix
    /// socket in `~/.local/share`, calls `gh`/`glab`, and `git worktree add`s into
    /// *sibling* dirs — all outside a workspace sandbox. So forcing the sandbox on
    /// would silently break the very flows this adapter enables. We deliberately
    /// leave `--sandbox` unset so Cursor honors the user's own sandbox config
    /// rather than imposing (or disabling) one.
    ///
    /// Still deliberately **not** used: `--yolo` (alias for `--force`, no added
    /// value), the undocumented/unstable `--auto-review`, and `--trust`
    /// (headless-only per the audit; this adapter uses the interactive TUI).
    public static func autoPermissionSuffix(_ autoPermissionMode: Bool) -> String {
        guard autoPermissionMode else { return "" }
        return " --force --approve-mcps"
    }
}
