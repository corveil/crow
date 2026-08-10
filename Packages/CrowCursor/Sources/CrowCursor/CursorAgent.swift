import Foundation
import CrowCore

/// `CodingAgent` conformer for the Cursor CLI (`agent` binary). Mirrors the
/// shape of `ClaudeCodeAgent` — resume on restart (`--continue`),
/// auto-permission flags for unattended `.job`/`.review`, and per-worktree
/// hook config with the Crow session UUID baked in (see
/// `CursorHookConfigWriter`, #829). Remote control is enabled: Cursor runs an
/// interactive TUI, so `crow send` (the agent-agnostic stdin-paste path in
/// `SessionService`) drives it; no per-launch RC flag needed. Cursor's hook
/// engine is a superset of Claude Code's — same exit-code 0/2 protocol,
/// accepts `CLAUDE_PROJECT_DIR` as an alias — which is why the
/// `HookConfigWriter` / `StateSignalSource` pair works rather than being a
/// no-op like Codex's per-session writer.
public struct CursorAgent: CodingAgent {
    public let kind: AgentKind = .cursor
    public let displayName: String = "Cursor"
    /// Visually distinct from Claude's `"sparkles"` and Codex's
    /// `"terminal.fill"`. Easy to swap once branding firms up.
    public let iconSystemName: String = "cursorarrow.rays"
    public let supportsRemoteControl: Bool = true
    /// Cursor's CLI binary is named `agent`, not `cursor`.
    ///
    /// `agent` is a generic name — CI runner installs (Azure DevOps, TeamCity)
    /// also ship a binary called `agent`, so the PATH-walk discovery in
    /// `CodingAgent.findBinary()` can in principle resolve a non-Cursor
    /// executable on a build machine. If that happens, set
    /// `defaults.binaries.cursor` to the absolute path of Cursor's CLI in
    /// `{devRoot}/.claude/config.json` — the explicit override is consulted
    /// before the PATH walk and pins the resolution. We accept the false-
    /// positive risk here (CROW-484) because real workstations don't usually
    /// have a competing `agent` on PATH, and the override knob exists for
    /// the exotic case.
    public let launchCommandToken: String = "agent"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: CursorLauncher

    /// Last-resort search paths for the `agent` binary (Cursor's CLI), used
    /// only when the configured `BinaryOverrides` and a PATH walk both miss.
    /// The Cursor app bundle's embedded CLI is usually symlinked into PATH or
    /// installed via the Cursor app's "Install 'cursor' command" action; this
    /// list is the historical hardcoded set we used to check first (CROW-484).
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/agent",
        "/usr/local/bin/agent",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agent").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = CursorHookConfigWriter(),
        stateSignalSource: any StateSignalSource = CursorSignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = CursorLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let agentPath = CursorLaunchArgs.shellQuote(findBinary() ?? "agent")
        // NB: `findBinary()` resolves to an absolute path here — Cursor is
        // registered as *known* regardless of PATH (#879), but only enters the
        // launchable `agents` map when it resolves, and `autoLaunchCommand` only
        // runs for a launchable agent. So the quoted form is `'/…/agent'` and
        // `AgentLaunch.commandLaunchesToken` still matches it via its `/` prefix
        // alternative. A bare `'agent'` (findBinary→nil) would NOT match that
        // regex — but that path is unreachable while the launch gate excludes
        // unavailable kinds.
        // The `--trust` workspace-trust seed (skips the folder-trust dialog on a
        // fresh worktree — the per-launch analogue of `ClaudeTrustSeeder`,
        // CROW-890) rides every launch path EXCEPT `.review`: a review working
        // tree is an attacker-controlled `gh` clone at the PR author's head, so —
        // mirroring the `session.kind != .review` guard on `CodexTrustSeeder` in
        // `SessionService` — Crow never auto-trusts it (the intent is that review
        // falls back to Cursor's folder-trust dialog; whether `--force` still
        // surfaces that dialog is unverified — see `CursorLaunchArgs.launchSuffix`
        // — but withholding `--trust` is never worse). The auto-permission
        // flags (`--force --approve-mcps`) still apply per the caller's opt-in,
        // including on `.review` (unchanged). See `CursorLaunchArgs` for why
        // `--sandbox` is left unset (#829). On the non-review paths the seed also
        // rides `--continue` resume — harmless: the first launch already recorded
        // the saved trust decision.
        let launchArgs = CursorLaunchArgs.launchSuffix(
            seedTrust: session.kind != .review,
            autoPermissionMode: autoPermissionMode)

        switch session.kind {
        case .work:
            // Interactive TUI — the user types their prompt. No env prefix
            // (Cursor reads `CURSOR_API_KEY` from the shell; GUI-stored creds
            // are inherited otherwise), no `--continue` (resume is scoped to
            // `.job`/`.review` restart, #829; a fresh work TUI without resume is
            // a deliberate product choice), no remote-control flag (remote
            // control is `crow send` typing into the TUI — agent-agnostic,
            // handled by the `send` RPC → `TerminalRouter.send`). The `--trust`
            // seed always applies, and the auto-permission flags when the opt-in
            // coder-view toggle is on (#586) — both come from `launchArgs`.
            return "\(agentPath)\(launchArgs)\n"
        case .job, .review:
            // Jobs and reviews share the same dispatch shape: a pre-written
            // initial prompt file (`.crow-job-prompt.md` / `.crow-review-prompt.md`)
            // is fed as the positional prompt on first launch so Cursor starts
            // working unattended. Cursor's interactive TUI accepts a positional
            // prompt directly, so this one session gives unattended dispatch,
            // full hook coverage (`CursorSignalSource`), and `crow send` remote
            // control at once — no headless `-p` chain needed (unlike
            // OpenCode's batch `run`, which *must* chain `--continue` for a
            // TUI). The auto-permission flags above make it truly hands-off.
            //
            // On subsequent app restarts we resume the conversation with
            // `--continue` (landed CLI 2026-01-16) instead of re-running the
            // whole prompt or dropping into a cold TUI (#829).
            //
            // Review prompts are agent-aware: SessionService.buildReviewPrompt
            // inlines the crow-review-pr SKILL body for Cursor so the `agent`
            // CLI gets a self-contained brief — no slash-command engine
            // needed (#431). `reviewPromptDispatched` gates both kinds.
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                return ShellLaunchArgs.evalPromptLaunch(
                    prefix: "\(agentPath)\(launchArgs)",
                    promptPath: promptPath)
            }
            return "\(agentPath)\(launchArgs) --continue\n"
        case .manager:
            // Manager sessions never auto-launch an agent — Crow drives them
            // externally. Returning nil here is the contract, not a gap.
            return nil
        }
    }

    public func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?,
        codeProvider: Provider?
    ) async -> String {
        await launcher.generatePrompt(
            session: session,
            worktrees: worktrees,
            ticketURL: ticketURL,
            provider: provider,
            codeProvider: codeProvider
        )
    }

    public func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String
    ) async throws -> String {
        // Fail closed (CROW-890 review, Yellow 2): the kindless three-argument
        // requirement can't prove a worktree is non-`.review`, so it never seeds
        // trust. It has no production caller — `SessionService.handoffAgent`
        // always calls the `sessionKind:` overload below — so this can't
        // under-trust a real launch; it just guarantees a hypothetical future
        // caller of the bare form gets the safe default rather than reopening the
        // review-clone hole. The kind-aware overload is the seeding path.
        try await launcher.launchCommand(
            sessionID: sessionID,
            worktreePath: worktreePath,
            prompt: prompt,
            binary: findBinary() ?? "agent",
            seedTrust: false
        )
    }

    /// Kind-aware handoff launch. Overrides the `CodingAgent` default so a
    /// `.review` handoff to Cursor does **not** carry the `--trust` seed — the
    /// review clone is attacker-controlled (a `gh` checkout at the PR author's
    /// head), so Crow does not auto-trust it, mirroring the `session.kind !=
    /// .review` guard on `CodexTrustSeeder` (CROW-890 review, Red 1).
    /// `SessionService.handoffAgent` calls this with the live `session.kind`;
    /// every other kind seeds trust as before.
    public func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String,
        sessionKind: SessionKind
    ) async throws -> String {
        try await launcher.launchCommand(
            sessionID: sessionID,
            worktreePath: worktreePath,
            prompt: prompt,
            binary: findBinary() ?? "agent",
            seedTrust: sessionKind != .review
        )
    }

    public func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        // Cursor's Manager is an orchestration TUI in the devRoot — no
        // auto-prompt, no `--continue`. Cursor has no `--rc`/`--name`
        // equivalent, so remote control doesn't apply (CROW-433). It carries the
        // `--trust` workspace-trust seed (the devRoot may be fresh to Cursor's
        // trust ledger — parity with Claude seeding the Manager cwd, CROW-890),
        // plus the auto-permission flags so `crow`/`gh`/`git` orchestration runs
        // without per-call approval when the Manager toggle is on (parity with
        // Claude's `--permission-mode auto`; `--sandbox` deliberately unset so
        // the Manager's out-of-workspace `crow`/`gh`/`git worktree` calls aren't
        // network/filesystem-blocked — see `CursorLaunchArgs`). Terminal backend
        // appends the submitting Enter, so we return the command without a
        // trailing newline to match the cross-agent convention.
        let agentPath = CursorLaunchArgs.shellQuote(findBinary() ?? "agent")
        return agentPath + CursorLaunchArgs.launchSuffix(
            seedTrust: true, autoPermissionMode: autoPermissionMode)
    }

    /// Cursor CLI exposes `/rename` for naming sessions (CROW-629).
    public func sessionRenameSlashCommand(newName: String) -> String? {
        "/rename \(newName)\n"
    }
}
