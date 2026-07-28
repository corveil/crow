import Foundation
import CrowCore

/// `CodingAgent` conformer for Grok Build (`xai-org/grok-build`, binary
/// `grok`) — xAI's official Rust coding-agent harness. Structurally mirrors
/// `OpenCodeAgent`: Grok runs an interactive TUI, so remote control is
/// `crow send` typing into the TUI (the agent-agnostic stdin path in
/// `SessionService`) rather than a launch flag, and its initial prompt uses
/// run-then-continue because any prompt argument forces headless mode.
///
/// Grok's hook schema is Claude/Cursor-compatible, so its state bridge is the
/// good tier: per-worktree `.grok/hooks/crow.json` with the session UUID baked
/// in (`GrokHookConfigWriter`, exact per-session resolution — no `cwd` match).
/// Project hooks require folder trust, seeded for Crow-created worktrees by
/// `GrokTrustSeeder` (never `.review` clones).
///
/// All flags verified against `xai-org/grok-build@main` (2026-07-25). That repo
/// is a periodic mirror of xAI's monorepo, closed to external PRs, so every
/// flag is a version-pinned re-check target — see `GrokLaunchArgs`,
/// `GrokSignalSource`, and `docs/agent-harness-matrix.md`.
public struct GrokAgent: CodingAgent {
    public let kind: AgentKind = .grok
    public let displayName: String = "Grok Build"
    /// Distinct from Claude's `"sparkles"`, Codex's `"terminal.fill"`,
    /// Cursor's `"cursorarrow.rays"`, and OpenCode's code-brackets glyph.
    public let iconSystemName: String = "bolt.fill"
    /// TUI is remote-driven by `crow send`, so remote control is supported even
    /// though the Phase-A adapter fakes it via stdin. Grok *does* have a native
    /// ACP app-server (`grok agent serve` / `grok agent stdio`); wiring that as
    /// real RC is deferred to Phase B (cf. Codex's experimental `remote-control`).
    public let supportsRemoteControl: Bool = true
    public let launchCommandToken: String = "grok"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: GrokLauncher

    /// Last-resort search paths for the `grok` binary, used only when the
    /// configured `BinaryOverrides` and a PATH walk both miss (CROW-484).
    ///
    /// ⚠️ **`grok` collides** with the community `superagent-ai/grok-cli`, which
    /// also installs a binary named `grok`. Like Cursor's generic `agent` token
    /// (CROW-484), we accept the false-positive risk — a real workstation rarely
    /// has both — and users pin xAI's Grok Build via `defaults.binaries.grok`
    /// in `{devRoot}/.claude/config.json`; the explicit override is consulted
    /// before the PATH walk (`BinaryOverrides`, keyed on `AgentKind.rawValue` =
    /// `"grok"`).
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/grok",
        "/usr/local/bin/grok",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/grok").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/bin/grok").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = GrokHookConfigWriter(),
        stateSignalSource: any StateSignalSource = GrokSignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = GrokLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let grokPath = findBinary() ?? "grok"

        switch session.kind {
        case .work:
            // Bare `grok` launch — the user types their prompt into the TUI. No
            // env prefix (Grok reads its creds from its own config), no `-c`
            // (MVP `.work` doesn't auto-resume), no remote-control flag (remote
            // control is `crow send` typing into the TUI — agent-agnostic).
            return GrokLaunchArgs.bareCommand(binary: grokPath)
        case .job, .review:
            // First launch runs the prompt file headlessly, then chains into
            // `-c` to resume in the interactive TUI (run-then-continue — any
            // prompt arg forces headless). Subsequent restarts skip the headless
            // re-run and resume the TUI only. `reviewPromptDispatched` gates both.
            //
            // Auto-permission is `.job`-only: reviews are human-gated (the
            // headless leg does the read-only analysis — read-only tools don't
            // prompt in Grok's default mode — and the human approves the final
            // `gh pr review` post in the resumed TUI). Review prompts are
            // agent-aware: SessionService.buildReviewPrompt inlines the
            // crow-review-pr SKILL body (Grok has no Crow slash-command engine).
            let autoForJob = (session.kind == .job) && autoPermissionMode
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                return GrokLaunchArgs.firstLaunchChainedCommand(
                    binary: grokPath,
                    promptPath: promptPath,
                    autoPermissionMode: autoForJob
                )
            }
            return GrokLaunchArgs.resumeTUICommand(
                binary: grokPath,
                autoPermissionMode: autoForJob
            )
        case .manager:
            // Manager sessions never auto-launch an agent — Crow drives them
            // externally. Matches Codex/OpenCode/Cursor's `.manager` contract.
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
        try await launcher.launchCommand(
            sessionID: sessionID,
            worktreePath: worktreePath,
            prompt: prompt,
            binary: findBinary() ?? "grok"
        )
    }

    public func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        // Grok's Manager is a plain TUI in the devRoot — no auto-prompt, no
        // remote-control / auto-permission knob (parity with Codex/OpenCode).
        // The terminal backend appends the submitting Enter, so we return the
        // bare command without a trailing newline. Shell-quoted (like
        // `CursorAgent.managerLaunchCommand`, the other colliding-token adapter):
        // `grok` collides with `superagent-ai/grok-cli`, so `defaults.binaries.grok`
        // is the *expected* config here, and an override path with a space would
        // otherwise word-split when the terminal backend runs it (#861 review r8).
        return GrokLaunchArgs.shellQuote(findBinary() ?? "grok")
    }

    /// Grok's TUI exposes `/rename` (alias `/title`) for the current session
    /// (verified in `docs/user-guide/04-slash-commands.md`), so a Crow rename
    /// stays in sync (CROW-629).
    public func sessionRenameSlashCommand(newName: String) -> String? {
        "/rename \(newName)\n"
    }
}
