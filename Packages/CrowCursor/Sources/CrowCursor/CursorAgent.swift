import Foundation
import CrowCore

/// `CodingAgent` conformer for the Cursor CLI (`agent` binary). Mirrors the
/// shape of `OpenAICodexAgent` but enables remote control — Cursor runs an
/// interactive TUI, so `crow send` (the agent-agnostic stdin-paste path in
/// `SessionService`) is sufficient for remote-driving it; no per-agent
/// hookery needed. Cursor's hook engine itself is a superset of Claude
/// Code's — same exit-code 0/2 protocol, accepts `CLAUDE_PROJECT_DIR` as
/// an alias — which is why the `HookConfigWriter` / `StateSignalSource`
/// pair below works rather than being a no-op like Codex's per-session
/// writer.
public struct CursorAgent: CodingAgent {
    public let kind: AgentKind = .cursor
    public let displayName: String = "Cursor"
    /// Visually distinct from Claude's `"sparkles"` and Codex's
    /// `"terminal.fill"`. Easy to swap once branding firms up.
    public let iconSystemName: String = "cursorarrow.rays"
    public let supportsRemoteControl: Bool = true
    /// Cursor's CLI binary is named `agent`, not `cursor`.
    public let launchCommandToken: String = "agent"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: CursorLauncher

    /// Standard search paths for the `agent` binary, in priority order.
    /// Homebrew-cask installs the Cursor app bundle at the first path on
    /// macOS; users who symlink the embedded CLI usually drop it there.
    static let cursorBinaryCandidates: [String] = [
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

    public func findBinary() -> String? {
        for path in Self.cursorBinaryCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let agentPath = findBinary() ?? "agent"

        switch session.kind {
        case .work:
            // Bare `agent` launch — the user types their prompt into the TUI.
            // No env prefix (Cursor reads `CURSOR_API_KEY` from the shell;
            // GUI-stored creds are inherited otherwise), no `--continue`
            // (MVP doesn't auto-resume), no remote-control flag (remote
            // control is `crow send` typing into the TUI — agent-agnostic,
            // handled by `SessionService.send`, not a per-launch flag).
            return "\(agentPath)\n"
        case .job:
            // Jobs write their first prompt to `.crow-job-prompt.md` in the
            // worktree before the terminal becomes shell-ready. On first
            // launch we pass that prompt as argv so Cursor starts working
            // unattended; on subsequent app restarts we fall back to a bare
            // `agent` (Cursor has no `--continue` equivalent in MVP), so the
            // user resumes the TUI rather than re-running the full prompt.
            if !session.reviewPromptDispatched {
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(".crow-job-prompt.md")
                return "\(agentPath) \"$(cat \(promptPath))\"\n"
            }
            return "\(agentPath)\n"
        case .review, .manager:
            // Review-on-Cursor isn't supported in Phase C — the review skill
            // is Claude-only. Manager sessions don't auto-launch an agent.
            return nil
        }
    }

    public func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?
    ) async -> String {
        await launcher.generatePrompt(
            session: session,
            worktrees: worktrees,
            ticketURL: ticketURL,
            provider: provider
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
        // Cursor's Manager is a plain orchestration TUI in the devRoot — no
        // auto-prompt, no `--continue`. Cursor has no `--rc`/`--name`
        // equivalent, so the remote-control / auto-permission knobs don't
        // apply (CROW-433).
        let agentPath = findBinary() ?? "agent"
        return "\(agentPath)\n"
    }
}
