import Foundation
import CrowCore

/// Helpers for building Muse Code (`muse`) launch commands. Centralized so
/// `MuseAgent`, `MuseLauncher`, and tests share one implementation of the
/// exec-then-resume dispatch form and the bounded auto-permission flags.
///
/// **Why exec-then-resume.** Muse has two launch surfaces with separate flag
/// sets ([configuration](https://dev.meta.ai/docs/muse-code/configuration)):
/// the interactive TUI (`muse`) and headless `muse exec`. A prompt argument
/// is headless-only (`muse exec --prompt-file <path>` / a positional). A
/// headless run exits when the turn finishes, which would strand a `.job`'s
/// typed follow-up prompts at the shell. So the first dispatch runs
/// `muse exec --prompt-file <path>` and then chains `; muse resume` to reopen
/// that workspace's session in the interactive TUI with a fresh stdin, so
/// `crow send` and `JobScheduler` follow-ups keep working — the same shape
/// `GrokLaunchArgs` / `OpenCodeLaunchArgs` use. `--prompt-file` (not a
/// `$(cat …)` subshell) so a large inlined review-skill body never becomes a
/// giant argv. Semicolon (not `&&`) so the TUI still opens if the headless
/// leg exits non-zero.
///
/// **Bounded auto-permission (never `--yolo`).** Muse's two layers are
/// independent ([permissions](https://dev.meta.ai/docs/muse-code/permissions)):
/// `--disable-approval` skips approval prompts but **keeps the OS sandbox**;
/// `--yolo` disables approval *and* the sandbox *and* trusts the workspace;
/// `--disable-sandbox` lifts filesystem confinement. The ADR-0015-honest
/// bounded posture is `--disable-approval` alone. Crow never emits `--yolo`
/// or `--disable-sandbox`.
///
/// **Workspace trust is a per-launch flag, not a durable store.**
/// `--trust-workspace` loads the checkout's skills, rules, and hooks. It is
/// emitted on `.work` / `.job` / Manager, and **withheld from `.review`**
/// (strip-not-trust — the clone is attacker-controlled). That is the Cursor
/// `--trust` analogue, scoped the way Codex/Grok withhold a *durable* trust
/// write from review.
///
/// **Never `--subagent-worktree-isolation`.** That opt-in makes Muse create
/// its own git worktrees per child, outside Crow's session tree. Crow does
/// not pass the flag; a user who enables it in `settings.json` is a
/// documented Crow risk (see the matrix).
///
/// Probed against official docs (https://dev.meta.ai/docs/muse-code/) on
/// 2026-08-14. No local `muse --help` was available — the installer is
/// Meta-auth-gated. Every flag is a version-pinned re-check target.
public enum MuseLaunchArgs {

    /// Bounded auto-permission flag suffix (leading space), or `""` when off.
    /// `--disable-approval` only — never `--yolo` / `--disable-sandbox`.
    public static func autoPermissionSuffix(autoPermissionMode: Bool) -> String {
        autoPermissionMode ? " --disable-approval" : ""
    }

    /// Per-launch workspace-trust flag (leading space), or `""` when withheld.
    /// Review clones must pass `false`.
    public static func trustSuffix(trustWorkspace: Bool) -> String {
        trustWorkspace ? " --trust-workspace" : ""
    }

    /// Combined flag suffix for a launch (auto-permission then trust).
    public static func flagSuffix(autoPermissionMode: Bool, trustWorkspace: Bool) -> String {
        autoPermissionSuffix(autoPermissionMode: autoPermissionMode)
            + trustSuffix(trustWorkspace: trustWorkspace)
    }

    /// First unattended dispatch: headless `muse exec --prompt-file <path>`
    /// consumes the prompt, then `; muse resume` reopens the TUI. `binary`
    /// and the prompt path are shell-quoted so a `defaults.binaries.muse`
    /// override or a worktree path with a space stays intact.
    public static func firstLaunchChainedCommand(
        binary: String,
        promptPath: String,
        autoPermissionMode: Bool,
        trustWorkspace: Bool
    ) -> String {
        let bin = ShellLaunchArgs.shellQuote(binary)
        let quotedPath = ShellLaunchArgs.shellQuote(promptPath)
        let flags = flagSuffix(
            autoPermissionMode: autoPermissionMode, trustWorkspace: trustWorkspace)
        return "\(headlessLeg(bin: bin, flags: flags, quotedPath: quotedPath))"
            + "; \(resumeLeg(bin: bin, flags: flags))\n"
    }

    /// The headless prompt-consuming leg. When bounded flags are present it
    /// appends an exit-2 fallback that re-runs the *bare* exec so a future
    /// `--disable-approval` / `--trust-workspace` rename still consumes the
    /// prompt rather than losing it forever (`launchAgent` sets
    /// `reviewPromptDispatched` unconditionally after dispatch). Gated on
    /// clap-style exit 2, not any non-zero — a mid-turn failure must not
    /// re-run the job. No fallback when flags are empty.
    static func headlessLeg(bin: String, flags: String, quotedPath: String) -> String {
        let flagged = "\(bin) exec\(flags) --prompt-file \(quotedPath)"
        guard !flags.isEmpty else { return flagged }
        return "\(flagged) || { [ $? -eq 2 ] && \(bin) exec --prompt-file \(quotedPath); }"
    }

    /// Resume the workspace's session in the interactive TUI (`muse resume`).
    /// Carries the same bounded flags as the first launch so a restarted
    /// unattended job does not stall at Muse's default approval prompt.
    public static func resumeTUICommand(
        binary: String,
        autoPermissionMode: Bool,
        trustWorkspace: Bool
    ) -> String {
        let bin = ShellLaunchArgs.shellQuote(binary)
        let flags = flagSuffix(
            autoPermissionMode: autoPermissionMode, trustWorkspace: trustWorkspace)
        return "\(resumeLeg(bin: bin, flags: flags))\n"
    }

    /// The interactive-resume leg. Same exit-2-gated fallback as the
    /// headless leg when flags are present, so an upstream flag rename
    /// still opens the TUI instead of killing the pane. A bare `||` would
    /// also reopen on Ctrl-C (130); `[ $? -eq 2 ]` does not.
    static func resumeLeg(bin: String, flags: String) -> String {
        let flagged = "\(bin)\(flags) resume"
        guard !flags.isEmpty else { return flagged }
        return "\(flagged) || { [ $? -eq 2 ] && \(bin) resume; }"
    }

    /// Bare interactive TUI launch — the `.work` path. Trust is optional so
    /// a future review-shaped interactive launch can withhold it; today's
    /// `.work` always passes `true`.
    public static func bareCommand(binary: String, trustWorkspace: Bool) -> String {
        "\(ShellLaunchArgs.shellQuote(binary))\(trustSuffix(trustWorkspace: trustWorkspace))\n"
    }

    /// Manager launch line: quoted binary + optional auto-perm + trust,
    /// **no** trailing newline (the terminal backend appends Enter).
    public static func managerCommand(
        binary: String,
        autoPermissionMode: Bool,
        trustWorkspace: Bool
    ) -> String {
        ShellLaunchArgs.shellQuote(binary)
            + flagSuffix(autoPermissionMode: autoPermissionMode, trustWorkspace: trustWorkspace)
    }
}
