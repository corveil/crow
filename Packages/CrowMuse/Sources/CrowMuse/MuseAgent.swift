import Foundation
import CrowCore

/// `CodingAgent` conformer for Muse Code (Meta's terminal coding agent, binary
/// `muse`). **Tier-2 / experimental** (ADR 0015): a real, driveable CLI that
/// lands below the self-hostable harnesses — closed-source and Meta-auth-locked
/// (browser sign-in or `META_API_KEY`), so it fails Corveil's self-host axis
/// permanently, the same class as Antigravity (#860).
///
/// Structurally a near-clone of `GrokAgent`: hooks are Claude-named lifecycle
/// events written to per-worktree `.muse/hooks.json`; remote control is faked
/// via `crow send` paste into the interactive TUI; `.job`/`.review` use
/// exec-then-resume (`muse exec --prompt-file` then `muse resume`) because any
/// prompt argument is headless-only. Workspace trust is the per-launch
/// `--trust-workspace` flag (Cursor `--trust` analogue), withheld from
/// `.review`. Auto-permission is the bounded `--disable-approval` (sandbox
/// stays) — never `--yolo`.
///
/// Flags verified against official docs (https://dev.meta.ai/docs/muse-code/)
/// on 2026-08-14. No local `muse --help` was available (installer is
/// Meta-auth-gated). Every flag is a version-pinned re-check target.
public struct MuseAgent: CodingAgent {
    public let kind: AgentKind = .muse
    public let displayName: String = "Muse Code"
    /// Distinct from Claude's `"sparkles"`, Cursor's `"cursorarrow.rays"`,
    /// Codex's `"terminal.fill"`, OpenCode's brackets, Grok's `"bolt.fill"`,
    /// and Antigravity's `"arrow.up.circle"`. Not `"music.note"` — that
    /// collides thematically with the Muse Sequencer binary of the same name.
    public let iconSystemName: String = "wand.and.stars"
    /// `true`, but faked: Muse has no `--rc`/`--name` protocol, so remote
    /// driving is `crow send` pasting into the interactive TUI (the
    /// agent-agnostic `TerminalRouter.send` path). The badge reflects that
    /// Crow *can* drive it, not a native RC surface — same as Grok/Antigravity.
    public let supportsRemoteControl: Bool = true
    public let launchCommandToken: String = "muse"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: MuseLauncher

    /// Runs the `--help` / `--version` identity probe. Injectable so tests can
    /// stub the binary's output without spawning a real subprocess; production
    /// uses `ProcessShellRunner`.
    private let probeRunner: any ShellRunner

    /// Last-resort search paths for the `muse` binary, used only when the
    /// configured `BinaryOverrides` and a PATH walk both miss.
    ///
    /// The official installer (`curl -fsSL https://dev.meta.ai/install.sh`)
    /// writes `${MUSE_INSTALL_DIR:-$HOME/.local/bin}/muse`. These are
    /// conservative standard-bin locations — Crow never downloads `muse`
    /// itself (same supply-chain posture as Antigravity). A bare PATH/fallback
    /// match is **identity-probed** because `muse` collides with the Muse
    /// Sequencer (`muse-sequencer.github.io`) and other same-named tools
    /// (`verifyBinaryIdentity`). An explicit `defaults.binaries.muse` pin
    /// is authoritative and skips the probe.
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/muse",
        "/usr/local/bin/muse",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/muse").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".muse/bin/muse").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = MuseHookConfigWriter(),
        stateSignalSource: any StateSignalSource = MuseSignalSource(),
        probeRunner: any ShellRunner = ProcessShellRunner()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.probeRunner = probeRunner
        self.launcher = MuseLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        // `launchBinary()`, not `findBinary()`: Muse identity-probes (`muse`
        // collides with the Muse Sequencer), and since CROW-1058 discovery may
        // probe past a failing candidate — so launch must read the verified
        // path rather than re-walking to the impostor at the head of the list.
        let musePath = launchBinary() ?? "muse"

        switch session.kind {
        case .work:
            // Bare interactive TUI — the user types their prompt. Trust the
            // Crow-created worktree so project hooks/skills/rules load. No
            // resume (a fresh work TUI launching bare is deliberate), no RC
            // flag (remote control is `crow send` into the TUI), no auto-perm
            // (the human is at the keyboard).
            return MuseLaunchArgs.bareCommand(binary: musePath, trustWorkspace: true)
        case .job, .review:
            // Jobs and reviews share one dispatch shape (collapsed so the two
            // can't drift): first launch runs `muse exec --prompt-file`, then
            // `; muse resume` opens the TUI. Subsequent restarts skip the
            // headless re-run. `reviewPromptDispatched` gates both.
            //
            // Auto-permission (`--disable-approval`, sandbox stays) is honored
            // for both kinds when the caller asks — `.job` so an unattended
            // scheduled prompt doesn't stall, `.review` so `gh pr review` can
            // post under default-on `reviewAutoPermissionMode`. Trust is
            // `.job`-only: review clones are strip-not-trust (attacker-
            // controlled `gh` checkout). Review prompts are agent-aware:
            // `SessionService.buildReviewPrompt` inlines the crow-review-pr
            // SKILL body (Muse has no Crow slash-command engine).
            let trust = session.kind == .job
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                return MuseLaunchArgs.firstLaunchChainedCommand(
                    binary: musePath,
                    promptPath: promptPath,
                    autoPermissionMode: autoPermissionMode,
                    trustWorkspace: trust
                )
            }
            return MuseLaunchArgs.resumeTUICommand(
                binary: musePath,
                autoPermissionMode: autoPermissionMode,
                trustWorkspace: trust
            )
        case .manager:
            // Manager sessions never auto-launch an agent — Crow drives them
            // externally. Matches Codex/OpenCode/Cursor/Grok's `.manager` contract.
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
        // Fail closed: a kindless signature cannot prove the worktree isn't
        // `.review`. `handoffAgent` calls the kind-aware overload below with
        // the live `session.kind`.
        try await launcher.launchCommand(
            sessionID: sessionID,
            worktreePath: worktreePath,
            prompt: prompt,
            binary: launchBinary() ?? "muse",
            trustWorkspace: false
        )
    }

    public func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String,
        sessionKind: SessionKind
    ) async throws -> String {
        // Strip-not-trust: match `autoLaunchCommand`. Review clones withhold
        // `--trust-workspace` so attacker-committed skills/rules (`.claude/`,
        // `.codex/`) that the launch-path strip does not remove stay unloaded.
        try await launcher.launchCommand(
            sessionID: sessionID,
            worktreePath: worktreePath,
            prompt: prompt,
            binary: launchBinary() ?? "muse",
            trustWorkspace: sessionKind != .review
        )
    }

    public func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        // Muse's Manager is a plain TUI in the devRoot. Trust so project
        // hooks load; honor auto-perm with the bounded flag. No `--rc`.
        // Terminal backend appends Enter, so no trailing newline. Quoted
        // so a spaced `defaults.binaries.muse` pin can't word-split.
        MuseLaunchArgs.managerCommand(
            binary: launchBinary() ?? "muse",
            autoPermissionMode: autoPermissionMode,
            trustWorkspace: true
        )
    }

    // `sessionRenameSlashCommand` is intentionally NOT overridden: Muse's
    // documented slash commands (`/new`, `/resume`, `/goal`, …) do not
    // include `/rename`, so it inherits the protocol's opt-out `nil`
    // rather than pasting a stray `/rename` into the model (CROW-629).
    // Override once a rename command is confirmed.

    /// Substrings that identify a resolved `muse` binary as Meta's Muse Code
    /// rather than the colliding Muse Sequencer (or any other `muse`). Matched
    /// case-insensitively against the combined `muse --help` + `muse --version`
    /// output; **any** one match confirms identity (OR, not AND) so a single
    /// upstream flag rename can't grey out a genuine install.
    ///
    /// These are Muse Code-specific **flag / subcommand names** already
    /// verified against the official docs in `MuseLaunchArgs`. Deliberately
    /// **not** vendor branding (`meta` / `facebook`): a foreign tool may
    /// mention those. The Sequencer's flag set (`--audio`, JACK/ALSA) shares
    /// none of these.
    ///
    /// ⚠️ **Version-pinned re-check target** — Muse Code's `--help` text is
    /// upstream and closed-source. If a rewrite ever drops all of these, the
    /// user's escape hatch is an explicit `defaults.binaries.muse` pin.
    static let identityMarkers = [
        "--disable-approval", "--trust-workspace", "--sandbox-network", "--prompt-file",
    ]

    /// Identity-probe the resolved `muse` binary before registration marks it
    /// available. Only reached for a PATH/fallback match: an explicit
    /// `defaults.binaries.muse` pin is trusted without probing
    /// (`AgentDiscovery.evaluate`).
    public func verifyBinaryIdentity(atPath path: String) async -> Bool {
        await BinaryIdentityProbe.matches(
            path: path,
            args: ["--help", "--version"],
            markers: Self.identityMarkers,
            runner: probeRunner)
    }
}
