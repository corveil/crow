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

    /// Runs the `--version` / `--help` identity probe. Injectable so tests can
    /// stub the binary's output without spawning a real subprocess; production
    /// uses `ProcessShellRunner` (the same runner provider backends use).
    private let probeRunner: any ShellRunner

    /// Last-resort search paths for the `grok` binary, used only when the
    /// configured `BinaryOverrides` and a PATH walk both miss (CROW-484).
    ///
    /// ⚠️ **`grok` collides** with the community `superagent-ai/grok-cli`, which
    /// also installs a binary named `grok`. So a bare PATH/fallback match is
    /// **identity-probed** before registration marks Grok Build available
    /// (`verifyBinaryIdentity` — a foreign `grok` is shown disabled, CROW-911).
    /// Users can also pin xAI's Grok Build via `defaults.binaries.grok` in
    /// `{devRoot}/.claude/config.json`; that explicit override is consulted
    /// before the PATH walk (`BinaryOverrides`, keyed on `AgentKind.rawValue` =
    /// `"grok"`) **and bypasses the probe** as authoritative.
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/grok",
        "/usr/local/bin/grok",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/grok").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/bin/grok").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = GrokHookConfigWriter(),
        stateSignalSource: any StateSignalSource = GrokSignalSource(),
        probeRunner: any ShellRunner = ProcessShellRunner()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.probeRunner = probeRunner
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
            // Interactive TUI — the user types their prompt. No env prefix
            // (Grok reads its creds from its own config), no `-c` (MVP `.work`
            // doesn't auto-resume), no remote-control flag (remote control is
            // `crow send` typing into the TUI — agent-agnostic). Crow Auto
            // maps to `--always-approve` + hard `--deny` so a ticket that
            // asks to open a PR can `gh pr create` without a second in-TUI
            // `/always-approve` (CROW-1037). Auto off stays a bare `grok`.
            return GrokLaunchArgs.bareCommand(
                binary: grokPath,
                autoPermissionMode: autoPermissionMode
            )
        case .job, .review:
            // First launch runs the prompt file headlessly, then chains into
            // `-c` to resume in the interactive TUI (run-then-continue — any
            // prompt arg forces headless). Subsequent restarts skip the headless
            // re-run and resume the TUI only. `reviewPromptDispatched` gates both.
            //
            // Auto-permission is `.work`/`.job` only: reviews stay human-gated
            // (the headless leg does the read-only analysis — read-only tools
            // don't prompt in Grok's default mode — and the human approves the
            // final `gh pr review` post in the resumed TUI). `.job` Auto is
            // `--always-approve` + `--deny`, same as `.work` (CROW-1037).
            // Review prompts are agent-aware: SessionService.buildReviewPrompt
            // inlines the crow-review-pr SKILL body (Grok has no Crow
            // slash-command engine).
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

    /// Substrings that identify a resolved `grok` binary as xAI's grok-build
    /// rather than the colliding community `superagent-ai/grok-cli`. Matched
    /// case-insensitively against the combined `grok --version` + `grok --help`
    /// output; **any** one match confirms identity (OR, not AND) so a single
    /// upstream flag rename can't grey out a genuine install, while the Node-
    /// based community CLI — which carries none of these — is rejected.
    ///
    /// These are all grok-build-specific **flag names** already verified against
    /// `xai-org/grok-build@main` in `GrokLaunchArgs` (headless + permission
    /// surface); clap lists every flag in `--help`, so a real grok-build always
    /// prints them. Deliberately **not** vendor branding (`xai` / `x.ai`): the
    /// community `grok-cli` is *itself* an xAI Grok API client and may reference
    /// xAI in its own help text, which would false-positive a branding match.
    /// The conversational Node CLI has a wholly different flag set (`--model`,
    /// `--api-key`, …) and none of these.
    ///
    /// ⚠️ **Version-pinned re-check target** — grok-build's `--help`/`--version`
    /// text is upstream (a PR-closed mirror of xAI's monorepo, same as the
    /// launch flags), so re-verify these markers on each sync. If a rewrite ever
    /// drops all of them, the user's escape hatch is an explicit
    /// `defaults.binaries.grok` pin, which bypasses this probe entirely.
    static let identityMarkers = [
        "--prompt-file", "--prompt-json", "--permission-mode", "--always-approve",
    ]

    /// Identity-probe the resolved `grok` binary before registration marks it
    /// available (CROW-911). Probes `grok --help` (and, only if that yields no
    /// marker, `grok --version`) and looks for any `identityMarkers` substring —
    /// a match means xAI's grok-build, no match means the colliding community
    /// `grok` and the agent is shown disabled.
    ///
    /// Only reached for a PATH/fallback match: an explicit `defaults.binaries.grok`
    /// pin is trusted without probing (`AgentDiscovery.evaluate`).
    public func verifyBinaryIdentity(atPath path: String) async -> Bool {
        // `--help` first: every marker is a `--help` flag, so a genuine
        // grok-build matches on the first spawn and `--version` never runs (one
        // fewer subprocess per boot). `--version` is only a fallback for a
        // foreign binary that prints its banner there instead. An empty result
        // (a binary that prints nothing, or a probe timeout) simply matches no
        // marker and returns false — no separate empty-string branch needed.
        await BinaryIdentityProbe.matches(
            path: path,
            args: ["--help", "--version"],
            markers: Self.identityMarkers,
            runner: probeRunner)
    }
}
