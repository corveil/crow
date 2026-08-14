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
    /// Cursor's interactive TUI paints inline in the main buffer and never
    /// issues `smcup`. `alternate-screen on` is therefore inert, and full-frame
    /// repaints silt up the 50k scrollback as duplicate-frame sediment
    /// (CROW-1008). Crow still classifies the window as an agent surface; the
    /// sediment kill is a `history-limit 0` clamp, not the alt buffer.
    public let usesAlternateScreen: Bool = false
    /// Cursor's CLI installs under **two** names for the same executable —
    /// `cursor-agent` and the generic `agent` — both symlinked into PATH from
    /// `~/.local/share/cursor-agent/versions/<v>/cursor-agent`. Crow prefers
    /// `cursor-agent`, which has no known collision.
    ///
    /// `agent` demonstrably does collide: **xAI's grok-build installs its own
    /// `~/.grok/bin/agent`**, and on a box with both, that one won the PATH walk.
    /// Crow then built a Cursor command and ran Grok's binary, which died on the
    /// first flag it doesn't have (`error: unexpected argument '--force' found`)
    /// — CROW-989, the collision CROW-484 accepted as a theoretical risk actually
    /// firing. CI runners (Azure DevOps, TeamCity) ship an `agent` too.
    ///
    /// Preferring the unambiguous name makes resolution independent of PATH
    /// order (`resolveBinary` is token-major: every PATH entry is searched for
    /// `cursor-agent` before any is searched for `agent`). The legacy name stays
    /// as an alias so an older install still resolves — and, if *that* is what
    /// resolves, `verifyBinaryIdentity` confirms it's really Cursor before
    /// registration marks the agent available. An explicit
    /// `defaults.binaries.cursor` pin still overrides everything and skips the
    /// probe.
    public let launchCommandToken: String = "cursor-agent"
    public let alternateLaunchCommandTokens: [String] = ["agent"]
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: CursorLauncher

    /// Runs the `--help` identity probe. Injectable so tests can stub the
    /// binary's output without spawning a real subprocess; production uses
    /// `ProcessShellRunner` (the same runner provider backends use).
    private let probeRunner: any ShellRunner

    /// Last-resort search paths for Cursor's CLI, used only when the configured
    /// `BinaryOverrides` and a PATH walk both miss. `cursor-agent` entries come
    /// first for the same reason the token does — a hardcoded `…/bin/agent` is
    /// just as capable of being grok-build's as a PATH one, and the identity
    /// probe covers a `.fallback` match exactly like a `.path` one.
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/cursor-agent",
        "/usr/local/bin/cursor-agent",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cursor-agent").path,
        "/opt/homebrew/bin/agent",
        "/usr/local/bin/agent",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agent").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = CursorHookConfigWriter(),
        stateSignalSource: any StateSignalSource = CursorSignalSource(),
        probeRunner: any ShellRunner = ProcessShellRunner()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.probeRunner = probeRunner
        self.launcher = CursorLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let agentPath = CursorLaunchArgs.shellQuote(findBinary() ?? launchCommandToken)
        // NB: `findBinary()` resolves to an absolute path here — Cursor is
        // registered as *known* regardless of PATH (#879), but only enters the
        // launchable `agents` map when it resolves **and passes the identity
        // probe** (CROW-989), and `autoLaunchCommand` only runs for a launchable
        // agent. So the quoted form is `'/…/cursor-agent'` and
        // `AgentLaunch.commandLaunchesToken` still matches it via its `/` prefix
        // alternative. A bare `'cursor-agent'` (findBinary→nil) would NOT match
        // that regex — but that path is unreachable while the launch gate
        // excludes unavailable kinds.
        // The `--trust` workspace-trust seed (skips the folder-trust dialog on a
        // fresh worktree — the per-launch analogue of `ClaudeTrustSeeder`,
        // CROW-890) rides EVERY launch path, `.review` included as of CROW-954.
        // The original review carve-out left unattended reviews stuck on
        // "Workspace Trust Required" while already carrying `--force`, so the
        // dialog gated nothing a reviewer could act on — and the clone's real
        // defense is `stripCursorConfigFromReviewClone`, which now re-runs on
        // every launch via `prepareWorktreeForAgentLaunch`. See
        // `CursorLaunchArgs.trustSuffix` for the full rationale. The
        // auto-permission flags (`--force --approve-mcps`) still apply per the
        // caller's opt-in (unchanged). See `CursorLaunchArgs` for why `--sandbox`
        // is left unset (#829). The seed also rides `--continue` resume —
        // harmless: the first launch already recorded the saved trust decision.
        let launchArgs = CursorLaunchArgs.launchSuffix(
            seedTrust: true,
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
            //
            // `endOfOptions: true` puts a literal `--` before the prompt (CROW-968).
            // `agent` is commander-based (`Usage: agent [options] [command]
            // [prompt...]`) and claims any argv element starting with `-` as an
            // option, so a prompt whose first character is a hyphen kills the
            // launch — which is exactly what the review SKILL's `---` frontmatter
            // did. Stripping that frontmatter is the fix; this is the belt to its
            // braces, and covers a user's job prompt that happens to start with
            // `-`. Verified against the installed binary: `agent --list-models
            // --bogus` errors, `agent --list-models -- --bogus` parses clean.
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                return ShellLaunchArgs.evalPromptLaunch(
                    prefix: "\(agentPath)\(launchArgs)",
                    promptPath: promptPath,
                    endOfOptions: true)
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
        // Seeds trust for every kind (CROW-954). The CROW-890 "fail closed"
        // default — never seed, because a kindless signature can't prove the
        // worktree isn't `.review` — is moot now that `.review` seeds too, so
        // Cursor no longer needs the kind-aware overload at all and the
        // `CodingAgent` protocol default (which drops `sessionKind` and lands
        // here) is correct for every caller.
        try await launcher.launchCommand(
            sessionID: sessionID,
            worktreePath: worktreePath,
            prompt: prompt,
            binary: findBinary() ?? launchCommandToken,
            seedTrust: true
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
        let agentPath = CursorLaunchArgs.shellQuote(findBinary() ?? launchCommandToken)
        return agentPath + CursorLaunchArgs.launchSuffix(
            seedTrust: true, autoPermissionMode: autoPermissionMode)
    }

    /// Cursor CLI exposes `/rename` for naming sessions (CROW-629).
    public func sessionRenameSlashCommand(newName: String) -> String? {
        "/rename \(newName)\n"
    }

    /// Substrings that identify a resolved binary as Cursor's CLI rather than
    /// another tool installed under the same name. Matched case-insensitively
    /// against `--help` output; **any** one match confirms identity (OR, not
    /// AND), so a single upstream flag rename can't grey out a genuine install.
    ///
    /// These are the flags this adapter actually hands the binary
    /// (`CursorLaunchArgs`: `--trust`, `--force --approve-mcps`) plus Cursor's
    /// two env-var names. That choice is deliberate: the probe then answers the
    /// question the launch actually depends on — *does this binary understand the
    /// flags we're about to pass it?* — which is precisely what CROW-989 got
    /// wrong. `--force` alone is excluded as too generic to discriminate.
    ///
    /// Deliberately **not** the `Usage:` line: `cursor-agent --help` prints
    /// `Usage: agent [options] …` (the binary reports its generic argv[0] name),
    /// so matching on "cursor-agent" there would reject every genuine install.
    ///
    /// Verified against the installed `cursor-agent 2026.08.04-aaa8809`, and
    /// checked negative against `grok 1.0.0` (grok-build's `agent`), whose help
    /// carries none of them — it offers `--always-approve` / `--allow` / `--deny`
    /// instead. ⚠️ Re-verify on each Cursor CLI baseline bump, alongside the
    /// launch flags in `CursorLaunchArgs` (they're the same upstream surface).
    /// If a rewrite ever drops all of them, the user's escape hatch is an
    /// explicit `defaults.binaries.cursor` pin, which bypasses this probe.
    static let identityMarkers = [
        "--approve-mcps", "--trust", "cursor_api_key", "cursor_api_endpoint",
    ]

    /// Identity-probe the resolved binary before registration marks Cursor
    /// available (CROW-989). Only reached for a PATH/`fallbackCandidates` match:
    /// an explicit `defaults.binaries.cursor` pin is trusted without probing
    /// (`AgentDiscovery.evaluate`).
    ///
    /// `--help` only — every marker is a `--help` string, and Cursor's
    /// `--version` prints a bare build stamp (`2026.08.04-aaa8809`) with no
    /// vendor text, so a second spawn could never match and would only slow boot.
    /// An empty result (a binary that prints nothing, or a probe timeout) matches
    /// no marker and returns false.
    public func verifyBinaryIdentity(atPath path: String) async -> Bool {
        await BinaryIdentityProbe.matches(
            path: path,
            args: ["--help"],
            markers: Self.identityMarkers,
            runner: probeRunner)
    }
}
