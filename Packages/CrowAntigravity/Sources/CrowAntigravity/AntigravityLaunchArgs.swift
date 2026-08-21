import Foundation
import CrowCore

/// Helpers for building the argument string appended to an `agy` (Google
/// Antigravity CLI) invocation. Centralized so `AntigravityAgent`, the
/// launcher, and tests share one implementation of the flag choices — mirrors
/// `CursorLaunchArgs` / `OpenCodeLaunchArgs` (#860).
public enum AntigravityLaunchArgs {
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
