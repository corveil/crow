import Foundation
import CrowCore

/// Helpers for building Grok Build launch commands. Centralized so `GrokAgent`,
/// `GrokLauncher`, and tests share one implementation of the per-kind dispatch
/// form and the bounded auto-permission flags.
///
/// **Launch shape is split by session kind (CROW-1144, grok 1.0.5).**
/// `-p`/`--single` and `--prompt-file` are *single-turn headless*: they print
/// to stdout and exit. A "turn" is a **full agentic loop run to completion**
/// (many tool loops), not a quick one-shot — so chaining `; grok -c` behind a
/// `--prompt-file` leg blocks the interactive TUI until the entire task
/// finishes (or forever, if the headless run stalls waiting for input it
/// can't get). That is the right shape for unattended `.job` / `.review`
/// (no mid-run steering), and the wrong shape for a seeded `.work` session,
/// which needs a steerable TUI from turn one.
///
/// - **`.work` seed** (workspace skill / handoff): positional `[PROMPT]` —
///   grok 1.0.5 `--help`: *"Initial prompt for the interactive session"* —
///   via `interactiveSeedCommand`. Ticket prompts are small. Guarded against
///   `ARG_MAX` (`argvPromptByteLimit`); a seed past the threshold falls back
///   to the headless chain rather than a `command too long` abort.
/// - **`.job` / `.review`:** headless `grok --prompt-file <path>` then
///   `; grok -c` (`firstLaunchChainedCommand`). `--prompt-file` (not
///   `-p "$(cat …)"`) so a large inlined review-skill body never becomes a
///   giant argv. The trailing `-c` is kept because jobs need `crow send` /
///   `JobScheduler` follow-ups and reviews need a human-gated `gh pr review`
///   in the resumed TUI. Semicolon (not `&&`) so the TUI still opens if the
///   headless leg exits non-zero, and — when the bounded auto flags are on —
///   **both** legs carry an `|| { [ $? -eq 2 ] && <bin> … }` fallback so a
///   *flag* rejection (clap usage error, exit 2 — upstream churn) degrades to
///   "prompt consumed / TUI open at Grok's default `ask` policy" rather than
///   a lost prompt and a dead pane. Gated on exit 2, not any non-zero, so a
///   mid-turn failure or Ctrl-C doesn't re-run the job or reopen the pane
///   (see `headlessLeg` / `resumeLeg`).
///
/// The 2026-07-25 probe (`xai-org/grok-build@main`,
/// `docs/user-guide/14-headless-mode.md`) claimed even a positional prompt
/// forced headless mode. **That is false for grok 1.0.5** — positional is the
/// interactive-seed path; only `-p` / `--prompt-file` / `--prompt-json` are
/// headless. Re-probe those flags on each upstream sync.
///
/// **Auto-permission = `--always-approve` + hard `--deny` (`.work` / `.job`).**
/// Grok has no sandbox flag. `--permission-mode auto` is a *classifier* that
/// still gates "external publish" (`gh pr create`, sometimes `git push`) even
/// when the ticket asked for it — that is **not** Claude's `--permission-mode
/// auto`, which lets a work session finish a ticket including publish. Crow's
/// Auto toggle therefore launches `--always-approve` (alias `--yolo` /
/// `--permission-mode bypassPermissions`) so `.work` coder views and unattended
/// `.job`s can `gh` / `git push` / `gh pr create` without a second in-TUI
/// `/always-approve`. Hard `--deny` guards stay on: Grok's docs say deny wins
/// over always-approve. Reviews stay human-gated (no auto flags). Auto off
/// still launches bare `grok`.
///
/// **Version-pinned re-check target (#859 / CROW-1037 / CROW-1144):** the #859
/// probe (@ 2026-07-25) reported *no* `--permission-mode auto` and claimed
/// positional = headless; grok **1.0.5** (2026-08-27) shows both
/// `--permission-mode` and `--always-approve`, and positional `[PROMPT]` as
/// interactive. Grok's repo is a periodic, PR-closed mirror of xAI's monorepo,
/// so re-probe `--always-approve`/`--yolo`, `--permission-mode`, `--allow`/
/// `--deny`, `-p`/`--single`, `--prompt-file`, positional `[PROMPT]`, and
/// `-c`/`-r` on each upstream sync.
public enum GrokLaunchArgs {

    /// Catastrophic-op hard denies applied whenever Crow Auto is on (`.work`
    /// and `.job`). Kept deliberately minimal — only patterns that are *never*
    /// legitimate ticket work — so `--always-approve` can run git / gh / edits /
    /// tests while deny still wins over a `rm -rf /`. A tuning/re-check seam:
    /// Grok's `--deny` rule grammar may churn upstream.
    static let hardDenyRules = [
        "Bash(rm -rf /)",
        "Bash(rm -rf /*)",
    ]

    /// Conservative ARG_MAX headroom for a positional `.work` seed (CROW-1144).
    /// Darwin `ARG_MAX` is 1 MiB, but the environment and `printf %q` expansion
    /// (which can roughly double the body) share that budget. 128 KiB of prompt
    /// is well above any ticket seed and well below the ceiling; a larger seed
    /// falls back to headless `--prompt-file` rather than a `command too long`
    /// abort. Mirrored as the `131072` byte check in `skills/crow-workspace/setup.sh`
    /// `launch_grok` — keep those in lockstep.
    public static let argvPromptByteLimit = 128 * 1024

    /// POSIX single-quote escape for paths interpolated into shell commands.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Auto-permission flag suffix (leading space), or `""` when off.
    /// `--always-approve` so Grok matches Claude Code Auto (`gh pr create`
    /// included), plus hard `--deny` guards (deny still wins).
    public static func autoPermissionSuffix(autoPermissionMode: Bool) -> String {
        guard autoPermissionMode else { return "" }
        var out = " --always-approve"
        for rule in hardDenyRules {
            out += " --deny \(shellQuote(rule))"
        }
        return out
    }

    /// Whether `prompt` is small enough to pass as a positional argv without
    /// risking `ARG_MAX`. Fail closed (`false`) is the headless fallback.
    public static func promptFitsArgv(_ prompt: String) -> Bool {
        prompt.utf8.count <= argvPromptByteLimit
    }

    /// Interactive TUI seeded with an initial prompt — the `.work` first-launch
    /// path (workspace skill / handoff). Grok 1.0.5's positional `[PROMPT]` is
    /// *"Initial prompt for the interactive session"*; `--prompt-file` / `-p`
    /// are single-turn *headless* and would run the whole agentic loop before
    /// the TUI ever opened (CROW-1144).
    ///
    /// Uses `ShellLaunchArgs.evalPromptLaunch` so the prompt body never rides
    /// the Crow `--command` / tmux paste (same as Claude/Cursor/Codex).
    /// `endOfOptions` is on: grok 1.0.5 clap says *"to pass '--bogus' as a
    /// value, use '-- --bogus'"*. `autoFlags` (when on) sit in the prefix,
    /// before `--`, so they stay flags.
    public static func interactiveSeedCommand(
        binary: String,
        promptPath: String,
        autoPermissionMode: Bool = false
    ) -> String {
        let bin = shellQuote(binary)
        let flags = autoPermissionSuffix(autoPermissionMode: autoPermissionMode)
        return ShellLaunchArgs.evalPromptLaunch(
            prefix: "\(bin)\(flags)",
            promptPath: promptPath,
            endOfOptions: true
        )
    }

    /// First unattended dispatch (`.job` / `.review`): headless
    /// `grok --prompt-file <path>` consumes the prompt, then `; grok -c`
    /// resumes it in the interactive TUI with a fresh stdin so `crow send` /
    /// follow-up prompts keep working. `autoFlags` (from `autoPermissionSuffix`)
    /// apply to both legs so a resumed unattended job stays auto-approving.
    /// Both `binary` and the prompt path are shell-quoted so a
    /// `defaults.binaries.grok` path or a worktree path with a space stays
    /// intact.
    ///
    /// Uses `--prompt-file <path>` rather than `-p "$(cat <path>)"` (#861 review
    /// round 5): Grok reads the file itself, so the prompt body never becomes a
    /// giant argv (large inlined review-skill bodies would risk `ARG_MAX`) and
    /// never rides through a `$(cat …)` subshell. Auto flags (when on) are
    /// `--always-approve` + `--deny`, not `--permission-mode auto`.
    ///
    /// **Not for `.work`.** Headless `--prompt-file` runs the whole task
    /// before exiting; chaining `-c` behind it is what stranded Grok work
    /// sessions with no TUI (CROW-1144). Use `interactiveSeedCommand`.
    public static func firstLaunchChainedCommand(
        binary: String,
        promptPath: String,
        autoPermissionMode: Bool
    ) -> String {
        let bin = shellQuote(binary)
        let quotedPath = shellQuote(promptPath)
        let flags = autoPermissionSuffix(autoPermissionMode: autoPermissionMode)
        return "\(headlessLeg(bin: bin, flags: flags, quotedPath: quotedPath))"
            + "; \(resumeLeg(bin: bin, flags: flags))\n"
    }

    /// Pick the `.work` seed shape: positional interactive TUI when the prompt
    /// fits argv, otherwise the headless chain so a huge seed never hits
    /// `ARG_MAX` (CROW-1144).
    public static func workSeedCommand(
        binary: String,
        promptPath: String,
        promptUTF8Count: Int,
        autoPermissionMode: Bool = false
    ) -> String {
        if promptUTF8Count <= argvPromptByteLimit {
            return interactiveSeedCommand(
                binary: binary,
                promptPath: promptPath,
                autoPermissionMode: autoPermissionMode
            )
        }
        return firstLaunchChainedCommand(
            binary: binary,
            promptPath: promptPath,
            autoPermissionMode: autoPermissionMode
        )
    }

    /// The headless prompt-consuming leg (`grok --prompt-file <p>`). Like
    /// `resumeLeg`, when the bounded flags are present it appends a fallback that
    /// re-runs the *bare* form so an `--always-approve`/`--deny` rename/removal
    /// still consumes the prompt at Grok's default `ask` policy — *more*
    /// restrictive than the dropped `--always-approve` + `--deny`, so nothing
    /// is loosened — instead of the prompt being lost forever. That loss is
    /// permanent without this: `launchAgent` sets `reviewPromptDispatched = true`
    /// unconditionally after dispatch, so a first launch whose headless leg failed
    /// never re-sends the prompt (#861 r13).
    ///
    /// The fallback is gated on **exit code 2** — clap's argument-parse failure —
    /// not any non-zero exit (#861 review r14). A blanket `||` would also re-run
    /// the whole job prompt when Grok fails *mid-turn* (API 5xx, tool error) after
    /// it already edited/committed, risking duplicated work; `[ $? -eq 2 ]`
    /// restricts the retry to a genuine usage error, where nothing ran first. No
    /// fallback when flags are empty (`.work` Auto-off / `.review`).
    static func headlessLeg(bin: String, flags: String, quotedPath: String) -> String {
        let flagged = "\(bin)\(flags) --prompt-file \(quotedPath)"
        guard !flags.isEmpty else { return flagged }
        return "\(flagged) || { [ $? -eq 2 ] && \(bin) --prompt-file \(quotedPath); }"
    }

    /// Resume the last Grok session in the interactive TUI (`-c`/`--continue`).
    /// Carries the bounded auto flags when they're on, so an unattended job
    /// resumed after a crowd/app restart doesn't stall at Grok's default `ask`
    /// policy. `binary` is shell-quoted (see `firstLaunchChainedCommand`).
    public static func resumeTUICommand(
        binary: String,
        autoPermissionMode: Bool
    ) -> String {
        let bin = shellQuote(binary)
        let flags = autoPermissionSuffix(autoPermissionMode: autoPermissionMode)
        return "\(resumeLeg(bin: bin, flags: flags))\n"
    }

    /// The interactive-resume leg (`grok -c`). When the bounded auto-permission
    /// flags are present, append a fallback that resumes *bare* if a future
    /// upstream rename/removal of `--always-approve`/`--deny` (this mirror churns
    /// — the #859 probe reported `--permission-mode auto` *absent*, current docs
    /// *present*, and `--always-approve` is the same surface) turns the flagged
    /// resume into a usage error, so the TUI still opens at Grok's default `ask`
    /// policy instead of the pane silently dying. The `;`-not-`&&` chain alone
    /// can't survive that, because the headless leg carries the *same* flags —
    /// so both flagged legs fail together, and every later `resumeTUICommand`
    /// restart fails identically.
    ///
    /// Gated on **exit code 2** (clap usage error), not any non-zero exit (#861
    /// review r14): a bare `||` would re-open the TUI on a user Ctrl-C (130) too,
    /// so the pane reopens Grok instead of returning to the shell. `[ $? -eq 2 ]`
    /// fires only on a genuine flag rejection. No fallback when flags are empty
    /// (`.work` Auto-off / `.review`): a bare `grok -c` has no flags to reject
    /// (#861 r12).
    static func resumeLeg(bin: String, flags: String) -> String {
        let flagged = "\(bin)\(flags) -c"
        guard !flags.isEmpty else { return flagged }
        return "\(flagged) || { [ $? -eq 2 ] && \(bin) -c; }"
    }

    /// Interactive TUI launch — the unseeded `.work` path, where the user types
    /// their prompt directly into Grok. When Crow Auto is on, carries
    /// `--always-approve` + `--deny` and the same exit-2 flag-rejection
    /// fallback as the job legs, so an upstream `--always-approve` rename still
    /// opens a TUI at Grok's default `ask` policy instead of a dead pane.
    /// `binary` is shell-quoted (see `firstLaunchChainedCommand`).
    public static func bareCommand(binary: String, autoPermissionMode: Bool = false) -> String {
        let bin = shellQuote(binary)
        let flags = autoPermissionSuffix(autoPermissionMode: autoPermissionMode)
        guard !flags.isEmpty else { return "\(bin)\n" }
        return "\(bin)\(flags) || { [ $? -eq 2 ] && \(bin); }\n"
    }
}
