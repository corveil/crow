import Foundation
import CrowCore

/// `CodingAgent` conformer for Claude Code. Wraps the existing `ClaudeLauncher`
/// prompt/launch-command logic and bundles the Claude-specific hook writer
/// and state-machine signal source so the main app can treat everything
/// through the generic `CodingAgent` interface.
public struct ClaudeCodeAgent: CodingAgent {
    public let kind: AgentKind = .claudeCode
    public let displayName: String = "Claude Code"
    public let iconSystemName: String = "sparkles"
    public let supportsRemoteControl: Bool = true
    public let launchCommandToken: String = "claude"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: ClaudeLauncher

    /// Last-resort search paths for the `claude` binary, used only when the
    /// configured `BinaryOverrides` and a PATH walk both miss. Claude Code
    /// installs via its installer to `~/.local/bin/claude` by default, which
    /// is the first hit on most setups; the homebrew paths cover users who
    /// symlinked the CLI into a system location (CROW-484).
    public let fallbackCandidates: [String] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = ClaudeHookConfigWriter(),
        stateSignalSource: any StateSignalSource = ClaudeHookSignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = ClaudeLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let claudePath = findBinary() ?? "claude"
        let rcArgs = ClaudeLaunchArgs.argsSuffix(
            remoteControl: remoteControlEnabled,
            sessionName: session.name,
            autoPermissionMode: autoPermissionMode
        )

        // OTEL telemetry env-var prefix when Crow's OTLP receiver is up.
        let envPrefix: String
        if let port = telemetryPort {
            let vars = [
                "CLAUDE_CODE_ENABLE_TELEMETRY=1",
                "OTEL_METRICS_EXPORTER=otlp",
                "OTEL_LOGS_EXPORTER=otlp",
                "OTEL_EXPORTER_OTLP_PROTOCOL=http/json",
                "OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:\(port)",
                "OTEL_RESOURCE_ATTRIBUTES=crow.session.id=\(session.id.uuidString)",
            ].joined(separator: " ")
            envPrefix = "export \(vars) && "
        } else {
            envPrefix = ""
        }

        // Review/job sessions read their pre-written prompt file on first
        // launch only — on subsequent app restarts, fall through to
        // `--continue` so the existing conversation resumes instead of
        // re-running the entire prompt (CROW-224, CROW-317). Work sessions
        // always resume. `reviewPromptDispatched` is reused as the generic
        // "initial prompt dispatched" gate.
        let initialPromptFile: String?
        switch session.kind {
        case .review:         initialPromptFile = ".crow-review-prompt.md"
        case .job:            initialPromptFile = ".crow-job-prompt.md"
        case .work, .manager: initialPromptFile = nil
        }
        if let initialPromptFile, !session.reviewPromptDispatched {
            let promptPath = (worktreePath as NSString)
                .appendingPathComponent(initialPromptFile)
            return "\(envPrefix)\(claudePath)\(rcArgs) \"$(cat \(promptPath))\"\n"
        }
        return "\(envPrefix)\(claudePath)\(rcArgs) --continue\n"
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
        let claudePath = findBinary() ?? "claude"
        return claudePath + ClaudeLaunchArgs.argsSuffix(
            remoteControl: remoteControlEnabled,
            sessionName: sessionName,
            autoPermissionMode: autoPermissionMode
        )
    }

    /// Claude Code's `/rename` keeps the claude.ai Remote Control panel label
    /// (and local session title) in sync with Crow (CROW-354 / CROW-629).
    public func sessionRenameSlashCommand(newName: String) -> String? {
        "/rename \(newName)\n"
    }
}
