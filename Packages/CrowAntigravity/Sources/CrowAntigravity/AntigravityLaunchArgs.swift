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

    /// The session-only `settings.json` override that selects Antigravity's
    /// **Auto** agent mode (CROW-1427). `--settings` takes "a JSON object of
    /// settings.json keys, inline or as a file path" and is "never saved", so
    /// the user's persisted `agentMode` is untouched.
    public static let autoModeSettingsJSON = #"{"agentMode":"auto"}"#

    /// Auto-permission flags. Returns a leading-space suffix or `""`.
    ///
    /// When on, this selects Antigravity's **Auto** agent mode (`agy` ≥ 1.3.5).
    /// Auto approves edits and safe commands, runs commands in the terminal
    /// sandbox, and sends any command that would leave the sandbox to a separate
    /// reviewer agent first. It is bounded: never `--dangerously-skip-permissions`,
    /// which stays a full bypass even after 1.5.2 narrowed it.
    ///
    /// **Why `--settings`, not `--mode auto` (probed on `agy` 1.5.5, CROW-1427).**
    /// On an account where Auto *is* available (`/config` and Shift+Tab both
    /// reach it), `--mode auto` is still a silent no-op:
    ///
    /// - **Interactive TUI:** the flag is applied before sign-in and the
    ///   experiment flags load, so `cli.log` records `auto mode is unavailable,
    ///   falling back to default`. The TUI shows no warning and comes up in
    ///   `default`.
    /// - **`-p`:** it prints `--mode auto is not available for this account;
    ///   continuing in the default mode` (log: `rollout flag off`) for the same
    ///   reason.
    ///
    /// `--settings '{"agentMode":"auto"}'` is applied after sign-in on both
    /// paths, so the session really runs in Auto (footer `auto ·`,
    /// `SetCycleMode called: auto`). It also beats a persisted `agentMode`: with
    /// `"agentMode": "plan"` in `~/.gemini/antigravity-cli/settings.json`, the
    /// flag still came up in Auto. That is the failure that sank Cursor's
    /// `--auto-review` (CROW-1345).
    ///
    /// **What a block looks like.** Inside the sandbox nothing is reviewed. The
    /// sandbox blocks network, `$HOME` and writes under `.git/`, so `gh`, the
    /// `crow` socket and a sibling `git worktree add` fail there first. The agent
    /// retries them outside the sandbox and the reviewer approved all three in
    /// the probe. When the reviewer reaches no verdict (seen on a feature-branch
    /// push):
    ///
    /// - `-p` soft-denies the command and the run continues (exit 0). Crow's
    ///   first `.job` launch uses `-p`, so it never hangs.
    /// - The interactive TUI shows a "Run this command?" card that waits until
    ///   someone answers. That is acceptable for the attended Manager and `.work`
    ///   TUI, and Antigravity's default `request-review` mode cards far more
    ///   often.
    ///
    /// For contrast, the default mode under `-p` soft-denies **every** command,
    /// so an Antigravity `.job` without this flag cannot even run `ls`.
    ///
    /// The caller decides which session kinds get it. `AntigravityAgent` keeps
    /// `.review` off, because review clones are attacker-controlled.
    public static func autoPermissionSuffix(_ autoPermissionMode: Bool) -> String {
        guard autoPermissionMode else { return "" }
        return " --settings " + shellQuote(autoModeSettingsJSON)
    }
}
