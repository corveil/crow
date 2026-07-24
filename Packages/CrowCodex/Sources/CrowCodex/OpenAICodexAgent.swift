import Foundation
import CrowCore

/// `CodingAgent` conformer for the OpenAI Codex CLI. Mirrors the shape of
/// `ClaudeCodeAgent` while honoring Codex's quirks — global `~/.codex/`
/// configuration and no `--rc` remote-control support.
///
/// `codex` 0.141.0 closed the early-MVP gaps (#830): restarts now `codex
/// resume --last`, reviews run the native `codex review --base` subcommand,
/// and unattended `.job` sessions dispatch `codex exec … -a never -s
/// workspace-write` (approval off, sandbox still bounded) instead of the
/// interactive TUI.
public struct OpenAICodexAgent: CodingAgent {
    public let kind: AgentKind = .codex
    public let displayName: String = "OpenAI Codex"
    /// Visually distinct from Claude's `"sparkles"`. Easy to swap once
    /// branding firms up.
    public let iconSystemName: String = "terminal.fill"
    public let supportsRemoteControl: Bool = false
    public let launchCommandToken: String = "codex"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: CodexLauncher

    /// Last-resort search paths for the `codex` binary, used only when the
    /// configured `BinaryOverrides` and a PATH walk both miss. Most users will
    /// resolve through PATH (codex ships via `npm i -g @openai/codex` and
    /// lives wherever the user's Node manager puts globals); this list is just
    /// the historical hardcoded set we used to check first (CROW-484).
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = CodexHookConfigWriter(),
        stateSignalSource: any StateSignalSource = CodexSignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = CodexLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let codexPath = findBinary() ?? "codex"

        switch session.kind {
        case .work:
            // App-restart / terminal-recovery path (`autoLaunchCommand` only
            // fires for restored terminals — brand-new `.work` sessions are
            // seeded by `launch_codex` in `crow-workspace/setup.sh` via
            // `--command`). Resume the most recent recorded thread instead of
            // reopening a blank TUI (#830 — the "no `--continue` in MVP" pin is
            // gone). `.work` threads are interactive, so plain `--last` selects
            // them. No env prefix (Codex has no OTEL equivalent), no `--rc`
            // (Codex doesn't do remote control). Mirrors Claude's `--continue`.
            return "\(codexPath) resume --last\n"
        case .job:
            if !session.reviewPromptDispatched {
                // First launch: feed `.crow-job-prompt.md` as the initial
                // message so Codex starts working unattended. `SessionService`
                // wrote the file and flips `reviewPromptDispatched` after the
                // command goes out.
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(".crow-job-prompt.md")
                let promptArg = "\"$(cat \(promptPath))\""
                if autoPermissionMode {
                    // Non-interactive headless run with approval off but the
                    // workspace-write sandbox still ON — the bounded default
                    // that matches Claude's `--permission-mode auto` (#830,
                    // scope-correction). Deliberately NOT
                    // `--dangerously-bypass-approvals-and-sandbox` /
                    // `-s danger-full-access`: those disable the sandbox and are
                    // only for externally-sandboxed runners. Flags precede the
                    // positional prompt so clap never mistakes prompt text for a
                    // `resume`/`review` subcommand.
                    return "\(codexPath) exec -a never -s workspace-write \(promptArg)\n"
                }
                // Interactive job (auto-permission off): drive the TUI with the
                // initial prompt so the user still approves each step.
                return "\(codexPath) \(promptArg)\n"
            }
            // Subsequent restarts resume the prior thread. `--include-non-
            // interactive` is required so `--last` can select a session that
            // first ran via `codex exec` (non-interactive), which the picker
            // otherwise skips.
            return "\(codexPath) resume --last --include-non-interactive\n"
        case .review:
            // Native review subcommand (#830 — "Phase C, Claude-only" no longer
            // holds). `codex review --base <branch>` reviews the checked-out PR
            // head against its base non-interactively; the inlined review-skill
            // brief the Claude/Cursor path feeds isn't needed for the review
            // itself. Base is captured at review-creation from the PR metadata;
            // fall back to `main` for legacy sessions that predate the field.
            let base = session.reviewBaseBranch ?? "main"
            return "\(codexPath) review --base \"\(base)\"\n"
        case .manager:
            // Manager sessions never auto-launch an agent — Crow drives them
            // externally. Matches `CursorAgent`'s `.manager` contract.
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
            prompt: prompt
        )
    }

    public func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        // Codex's Manager is a plain TUI in the devRoot — no auto-prompt,
        // no remote-control, no auto-permission knob (CROW-433). Terminal
        // backend appends the submitting Enter, so we return the bare
        // command without a trailing newline.
        return findBinary() ?? "codex"
    }

    /// Codex TUI exposes `/rename` for the current thread (CROW-629).
    public func sessionRenameSlashCommand(newName: String) -> String? {
        "/rename \(newName)\n"
    }
}
