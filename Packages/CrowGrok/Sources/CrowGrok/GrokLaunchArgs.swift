import Foundation

/// Helpers for building Grok Build launch commands. Centralized so `GrokAgent`,
/// `GrokLauncher`, and tests share one implementation of the run-then-continue
/// dispatch form and the bounded auto-permission flags.
///
/// **Why run-then-continue.** Every way to pass a prompt to `grok` non-
/// interactively — `-p`/`--single`, `--prompt-file`, `--prompt-json`, and even
/// a positional — triggers **headless mode** (verified against
/// `xai-org/grok-build@main`, 2026-07-25, `docs/user-guide/14-headless-mode.md`).
/// Headless runs one turn and exits, which would strand a `.job`'s typed
/// follow-up prompts at the shell. So the first dispatch runs the prompt
/// headlessly (`grok --prompt-file <path>`) and then chains `; grok -c` to
/// resume that same session in the interactive TUI with a fresh stdin, so
/// `crow send` and `JobScheduler` follow-ups keep working — the same shape
/// `OpenCodeLaunchArgs` uses. `--prompt-file` (not `-p "$(cat …)"`) so a large
/// inlined review-skill body never becomes a giant argv or rides a `$(cat …)`
/// subshell. Semicolon (not `&&`) so the TUI still opens if the headless leg
/// exits non-zero.
///
/// **Bounded auto-permission (`.job` only, never `--yolo`).** Grok has no
/// sandbox flag; its only prompt-reducing modes are `--permission-mode auto`
/// (a classifier auto-approves read-only/safe tools and still gates dangerous
/// ones — the direct analog of Claude's `--permission-mode auto`) and
/// `--always-approve` (alias `--yolo`, = `--permission-mode bypassPermissions`,
/// a *full* bypass). The ADR-0015-honest bounded posture is the former plus
/// hard `--deny` guards (deny wins over auto and over always-approve), **not**
/// the bypass. Consequence, documented in the matrix: a genuinely dangerous op
/// in an unattended job still gates rather than running — the honest trade-off.
///
/// **Version-pinned re-check target (#859):** the ticket's pinned probe (@
/// 2026-07-25) reported *no* `--permission-mode auto`; the current docs show it
/// (`grok --permission-mode auto`). Grok's repo is a periodic, PR-closed mirror
/// of xAI's monorepo, so re-probe `--permission-mode`, `--allow`/`--deny`,
/// `-p`/`--single`, and `-c`/`-r` on each upstream sync.
public enum GrokLaunchArgs {

    /// Catastrophic-op hard denies applied to bounded `.job` launches. Kept
    /// deliberately minimal — only patterns that are *never* legitimate job
    /// work — so `--permission-mode auto` remains the primary prompt-reducer and
    /// this doesn't over-restrict normal job operations (git, gh, edits, tests).
    /// A tuning/re-check seam: Grok's `--deny` rule grammar may churn upstream.
    static let jobDenyRules = [
        "Bash(rm -rf /)",
        "Bash(rm -rf /*)",
    ]

    /// POSIX single-quote escape for paths interpolated into shell commands.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Bounded auto-permission flag suffix for an unattended `.job` (leading
    /// space), or `""` when off. `--permission-mode auto` + hard `--deny`
    /// guards — never `--always-approve` / `--yolo`.
    public static func autoPermissionSuffix(autoPermissionMode: Bool) -> String {
        guard autoPermissionMode else { return "" }
        var out = " --permission-mode auto"
        for rule in jobDenyRules {
            out += " --deny \(shellQuote(rule))"
        }
        return out
    }

    /// First unattended dispatch: headless `grok --prompt-file <path>` consumes
    /// the prompt, then `; grok -c` resumes it in the interactive TUI with a
    /// fresh stdin so `crow send` / follow-up prompts keep working. `autoFlags`
    /// (from `autoPermissionSuffix`) apply to both legs so a resumed unattended
    /// job stays auto-approving. Both `binary` and the prompt path are
    /// shell-quoted so a `defaults.binaries.grok` path or a worktree path with a
    /// space stays intact.
    ///
    /// Uses `--prompt-file <path>` rather than `-p "$(cat <path>)"` (#861 review
    /// round 5): Grok reads the file itself, so the prompt body never becomes a
    /// giant argv (large inlined review-skill bodies would risk `ARG_MAX`) and
    /// never rides through a `$(cat …)` subshell. `--prompt-file` triggers the
    /// same headless mode as `-p` (verified, `14-headless-mode.md`), so the
    /// run-then-continue shape is unchanged.
    public static func firstLaunchChainedCommand(
        binary: String,
        promptPath: String,
        autoPermissionMode: Bool
    ) -> String {
        let bin = shellQuote(binary)
        let quotedPath = shellQuote(promptPath)
        let flags = autoPermissionSuffix(autoPermissionMode: autoPermissionMode)
        return "\(bin)\(flags) --prompt-file \(quotedPath)"
            + "; \(bin)\(flags) -c\n"
    }

    /// Resume the last Grok session in the interactive TUI (`-c`/`--continue`).
    /// Carries the bounded auto flags when they're on, so an unattended job
    /// resumed after a crowd/app restart doesn't stall at Grok's default `ask`
    /// policy. `binary` is shell-quoted (see `firstLaunchChainedCommand`).
    public static func resumeTUICommand(
        binary: String,
        autoPermissionMode: Bool
    ) -> String {
        let flags = autoPermissionSuffix(autoPermissionMode: autoPermissionMode)
        return "\(shellQuote(binary))\(flags) -c\n"
    }

    /// Bare interactive TUI launch — the `.work` path, where the user types
    /// their prompt directly into Grok. `binary` is shell-quoted (see
    /// `firstLaunchChainedCommand`).
    public static func bareCommand(binary: String) -> String {
        "\(shellQuote(binary))\n"
    }
}
