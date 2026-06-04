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

    /// Standard search paths for the `codex` binary, in priority order.
    /// Homebrew-cask installs Codex at the first path on macOS.
    static let codexBinaryCandidates: [String] = [
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

    public func findBinary() -> String? {
        for path in Self.codexBinaryCandidates {
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
        // Review-on-Codex isn't supported in Phase C — the review skill is
        // Claude-only. Returning nil tells `SessionService.launchAgent` to
        // log and skip rather than producing a malformed command.
        guard session.kind == .work else { return nil }

        // Bare `codex` launch — the user types their prompt into the TUI.
        // No env prefix (Codex has no OTEL equivalent), no `--continue`
        // (MVP doesn't auto-resume), no `--rc` (Codex doesn't do remote
        // control). The terminal's cwd is already the worktree path.
        return "codex\n"
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
        // Codex's Manager is a plain TUI in the devRoot — no auto-prompt,
        // no remote-control, no auto-permission knob (CROW-433).
        let codexPath = findBinary() ?? "codex"
        return "\(codexPath)\n"
    }
}
