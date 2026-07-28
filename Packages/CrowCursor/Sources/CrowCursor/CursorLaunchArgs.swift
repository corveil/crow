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

    /// Workspace-trust seed appended to **every** Crow-launched Cursor command
    /// (auto-launch, Manager, and the handoff one-shot). A leading-space suffix
    /// so callers concatenate it onto the shell-quoted binary path.
    ///
    /// `--trust` trusts the current workspace up front, skips the "Do you trust
    /// the files in this folder?" dialog, and records the same saved trust
    /// decision as accepting it (per the [changelog](https://cursor.com/docs/cli/changelog):
    /// "recording the same saved trust decision the dialog writes when you
    /// accept" — the `--help` line is terser). This is the per-launch analogue
    /// of `ClaudeTrustSeeder` (which pre-writes `hasTrustDialogAccepted` into
    /// `~/.claude.json`) and `CodexTrustSeeder` (`trust_level = "trusted"` in
    /// `~/.codex/config.toml`): Cursor tracks trust per workspace and it doesn't
    /// inherit, so a fresh worktree would otherwise block an auto-launched
    /// session on the folder-trust prompt (CROW-890 — closes the residual gap
    /// #829 deliberately left open).
    ///
    /// **Withheld from `.review` sessions** (see `launchSuffix`), mirroring the
    /// `session.kind != .review` guard on `CodexTrustSeeder`: a review working
    /// tree is an attacker-controlled `gh` clone, so it is never auto-trusted.
    ///
    /// **Interactive as of Cursor CLI 2026.07.20**
    /// ([changelog](https://cursor.com/docs/cli/changelog): "`--trust` works in
    /// interactive sessions"), verified empirically against `agent 2026.07.23`
    /// whose `--help` lists `--trust` as a general flag with **no "(headless mode
    /// only)" qualifier** and **no `--print` gating** (unlike `--output-format`).
    /// The [parameter reference](https://cursor.com/docs/cli/reference/parameters)
    /// still says headless-only, but the installed binary's own help is
    /// authoritative and disagrees — which is why the earlier audit's
    /// headless-only omission is now reversed.
    ///
    /// **Bounded to workspace trust — NOT `--yolo`/full-bypass.** It only
    /// suppresses the folder-trust dialog; per-tool approval still applies unless
    /// `autoPermissionSuffix` adds `--force`. Trust and auto-permission are
    /// orthogonal, so this seed is unconditional (outside `.review`) while
    /// `--force --approve-mcps` stays gated on the caller's opt-in (see
    /// `launchSuffix`).
    ///
    /// **Minimum Cursor CLI: ≥ 2026.07.20** — the build that made `--trust`
    /// interactive. Emitted on every non-`.review` launch path, so on an older
    /// binary the effect depends on that binary's handling. `--trust` has been a
    /// *recognized* flag since before 07.20 (the param reference lists it,
    /// headless-only), so an older `agent` parses it rather than erroring on an
    /// unknown option. **Probed 2026.07.23:** the arg parser silently *ignores* a
    /// `--print`-only flag used outside print mode — `agent --output-format json
    /// --version` exits 0 and prints the version, no error — so an older build
    /// recognizing `--trust` outside `--print` would no-op it and degrade to the
    /// old fresh-worktree prompt, **not** reject the launch (a cross-version
    /// inference on the same commander-based parser, now grounded in observed
    /// behavior). If a user on an older CLI ever reports broken launches, gate
    /// emission on a version check. Floor also recorded in the matrix re-check
    /// row and ADR 0015.
    public static let trustSuffix = " --trust"

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
    /// value) and the undocumented/unstable `--auto-review`. (`--trust` *is* now
    /// emitted — but as the separate, unconditional `trustSuffix` workspace-trust
    /// seed, not an auto-permission flag; see `trustSuffix` / `launchSuffix`.)
    public static func autoPermissionSuffix(_ autoPermissionMode: Bool) -> String {
        guard autoPermissionMode else { return "" }
        return " --force --approve-mcps"
    }

    /// The full flag suffix for a Crow-driven (non-handoff) Cursor launch: the
    /// `--trust` seed when `seedTrust` is on, plus `--force --approve-mcps` when
    /// the caller opted into auto-permission. Callers append it to the
    /// shell-quoted binary path.
    ///
    /// `seedTrust` is `session.kind != .review` at the call sites. A `.review`
    /// working tree is a `gh` clone checked out at the PR author's head
    /// (attacker-controlled), so — mirroring the `session.kind != .review` guard
    /// on `CodexTrustSeeder` in `SessionService` — it is **never** auto-trusted:
    /// review keeps Cursor's folder-trust dialog as its human gate (CROW-890
    /// review, Red 1). Auto-permission is orthogonal and unchanged on `.review`.
    /// `.work`/`.job` worktrees branch off a trusted base and the Manager runs in
    /// the devRoot, so those seed normally.
    public static func launchSuffix(seedTrust: Bool, autoPermissionMode: Bool) -> String {
        (seedTrust ? trustSuffix : "") + autoPermissionSuffix(autoPermissionMode)
    }
}
