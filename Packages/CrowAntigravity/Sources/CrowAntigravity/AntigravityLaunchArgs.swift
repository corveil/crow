import Foundation

/// Helpers for building the argument string appended to an `agy` (Google
/// Antigravity CLI) invocation. Centralized so `AntigravityAgent`, the
/// launcher, and tests share one implementation of the flag choices — mirrors
/// `CursorLaunchArgs` / `OpenCodeLaunchArgs` (#860).
public enum AntigravityLaunchArgs {
    /// POSIX single-quote escape for safe interpolation into a shell command line.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `agy`'s native, session-scoped Remote Control flag (CROW-1428; `agy`
    /// 1.2.6+, probed live on **1.4.6**). Each interactive `agy` process opens
    /// its own connection — two concurrent per-worktree sessions get two
    /// distinct `antigravity.google.com/r/<id>` URLs and hostname labels — and
    /// tears it down when the process exits. It is not the machine-global
    /// `agy remote-control start` OS service, which Crow never runs (the same
    /// brittle-reject class as Codex's `app-server daemon`, CROW-1001).
    public static let remoteControlFlag = "--remote-control"

    /// Leading-space Remote Control suffix for an **interactive** `agy` launch,
    /// or `""` when the toggle is off.
    ///
    /// The flag sits behind a shell-time `AGY_ADC_AUTH` guard. Remote Control
    /// does not support Application Default Credentials, and with ADC sign-in
    /// `agy --remote-control` exits 2 (`--remote-control is not supported when
    /// using Application Default Credentials (ADC)`) instead of starting the
    /// TUI. Crow can't see that variable: it is usually exported from the
    /// user's shell rc, not `crowd`'s environment. So the pane's shell decides
    /// at launch time. When `AGY_ADC_AUTH` is non-empty the flag is dropped and
    /// the session launches as it did before this change, driven by
    /// `crow send` only. Any non-empty value counts as ADC, so an odd value
    /// costs Remote Control, never the launch.
    ///
    /// The guard uses `$(…)`, like `ShellLaunchArgs.evalPromptLaunch`; launch
    /// lines already assume a POSIX-family shell. It is not used on the `-p`
    /// print path. A print turn is unattended and exits when it finishes, and
    /// `agy -p --remote-control` prints no connection URL to follow.
    public static func remoteControlSuffix(_ remoteControlEnabled: Bool) -> String {
        guard remoteControlEnabled else { return "" }
        return " $([ -n \"${AGY_ADC_AUTH-}\" ] || printf %s \(remoteControlFlag))"
    }

    /// Auto-permission flags for unattended `.job` launches. Returns a
    /// leading-space suffix or `""`.
    ///
    /// **Deliberately empty on `agy` v1.1.7 — a documented Tier-2 gap, not an
    /// oversight (#860).** Antigravity governs approval posture through
    /// `settings.json` *modes* — `proceed-in-sandbox` (bounded auto-proceed),
    /// `request-review` (the interactive default), and `strict` — plus the
    /// full-danger escapes `always-proceed` / `--dangerously-skip-permissions`.
    /// There is **no verified interactive launch flag** on this pinned version
    /// that selects the bounded `proceed-in-sandbox` mode without escalating to
    /// the full-danger bypass, and headless `-p` is separately known to ignore
    /// `permissions.allow` (upstream issue #548). So rather than assert an
    /// unverified flag or reach for `--dangerously-skip-permissions` (which we
    /// **never** pass — it removes the sandbox entirely, the opposite of the
    /// "bounded" posture the ticket asks for), an unattended `.job` runs under
    /// whatever mode the user configured in `settings.json`. That means a job
    /// can still stall at Antigravity's `request-review` gate — the same
    /// honest, interactive-reliable-only property Codex's `.review` has.
    ///
    /// The parameter is kept so every call site (`autoLaunchCommand`,
    /// `managerLaunchCommand`) has the uniform cross-agent shape; wiring a real
    /// bounded flag (or seeding `proceed-in-sandbox` into a per-worktree
    /// `settings.json`) is a version-pinned follow-up if `agy` grows a stable
    /// interactive selector.
    public static func autoPermissionSuffix(_ autoPermissionMode: Bool) -> String {
        // Intentionally a no-op today — see the doc comment above. Kept as a
        // function (not a dropped parameter) so a future bounded flag lands here
        // and every caller inherits it at once.
        _ = autoPermissionMode
        return ""
    }
}
