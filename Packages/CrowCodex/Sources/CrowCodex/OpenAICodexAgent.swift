import Foundation
import CrowCore

/// `CodingAgent` conformer for the OpenAI Codex CLI. Mirrors the shape of
/// `ClaudeCodeAgent` while honoring Codex's quirks — global `~/.codex/`
/// configuration, no `--rc` remote-control support, no `--continue`-style
/// resume in MVP.
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
            // Bare `codex` launch — `.work` has no in-app prompt-file
            // convention (`SessionService.initialPromptFileName` only fires
            // for `.job`/`.review`). Skill-created `.work` sessions are
            // seeded by `launch_codex` in `crow-workspace/setup.sh`, which
            // feeds the prompt at first-launch time via `--command` (#492);
            // the in-app resume path here just reopens the TUI. No env
            // prefix (Codex has no OTEL equivalent), no `--continue` (MVP
            // doesn't auto-resume), no `--rc` (Codex doesn't do remote
            // control).
            return "\(codexPath)\n"
        case .job, .workerRun:
            // First launch: feed `.crow-job-prompt.md` as the positional
            // initial message so Codex starts working unattended. A Corveil
            // worker run (corveil/crow#801) reuses the same prompt-file
            // convention in its scratch workdir, so it shares this branch.
            // `SessionService.launchAgent` wrote the file before invoking us
            // and flips `reviewPromptDispatched` (the generic "initial
            // prompt dispatched" gate) after the command goes out.
            // Subsequent restarts fall back to bare `codex` — Codex has no
            // `--continue` equivalent in MVP, so the user just resumes the
            // TUI rather than re-running the whole prompt (CROW-493).
            // Mirrors `CursorAgent.autoLaunchCommand`'s `.job` branch.
            if !session.reviewPromptDispatched {
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(".crow-job-prompt.md")
                return "\(codexPath) \"$(cat \(promptPath))\"\n"
            }
            return "\(codexPath)\n"
        case .review:
            // Review-on-Codex isn't supported in Phase C — the
            // `/crow-review-pr` skill is Claude-only. Returning nil tells
            // `SessionService.launchAgent` to log the skip and paste a
            // user-facing `⚠️` echo.
            return nil
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
