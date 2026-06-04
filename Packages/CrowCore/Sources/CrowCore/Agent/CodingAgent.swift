import Foundation

/// A coding agent that Crow can launch in a terminal and observe via hook
/// events. Phase A wraps the existing Claude Code integration; later phases
/// introduce additional conformers.
public protocol CodingAgent: Sendable {
    /// Stable identifier for this agent implementation.
    var kind: AgentKind { get }

    /// Human-readable name shown in pickers, tooltips, and the session detail
    /// header (e.g. "Claude Code").
    var displayName: String { get }

    /// SF Symbol name rendered in the sidebar row and pickers. Kept as a
    /// string so `CrowCore` stays SwiftUI-free; consumers resolve it via
    /// `Image(systemName:)`.
    var iconSystemName: String { get }

    /// Whether this agent supports Crow's "remote control" feature (the
    /// `--rc --name` flags Claude Code uses to register a session in
    /// claude.ai's Remote Control panel). Drives whether the
    /// `RemoteControlBadge` is shown for this agent's sessions.
    var supportsRemoteControl: Bool { get }

    /// The shell token that identifies a command as launching this agent.
    /// Used by the `send` RPC handler to decide whether a managed-terminal
    /// command needs hook-config + env-var prep before being forwarded.
    /// Examples: `"claude"`, `"codex"`.
    var launchCommandToken: String { get }

    /// Writer for the per-worktree hook configuration file.
    var hookConfigWriter: any HookConfigWriter { get }

    /// State-machine implementation that converts hook events into
    /// `AgentStateTransition` values.
    var stateSignalSource: any StateSignalSource { get }

    /// Resolve this agent's binary on disk, or return `nil` if it isn't
    /// installed. Drives binary-presence gating for the per-session picker
    /// and the launch-command builder below.
    func findBinary() -> String?

    /// Build the full shell command (ending with `\n`) that auto-launches
    /// this agent in `worktreePath`. Returns `nil` when the agent can't be
    /// launched — typically because the binary is missing or the session
    /// kind is unsupported.
    ///
    /// `autoPermissionMode` requests that the agent skip per-call permission
    /// prompts where possible (used for unattended `.job` sessions). Agents
    /// that don't surface this concept can ignore it.
    func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String?

    /// Build the initial prompt for this agent based on the session context.
    func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?
    ) async -> String

    /// Materialize `prompt` to disk (if needed) and return the shell command
    /// that starts the agent with that prompt in `worktreePath`.
    func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String
    ) async throws -> String

    /// Build the shell command that the Manager tab uses to launch this
    /// agent in the devRoot. Unlike `autoLaunchCommand`, this is the
    /// terminal's pre-populated `command` string — it runs before the
    /// shell prompt is ready, with no auto-prompt or `--continue` flag.
    ///
    /// `sessionName` labels the agent's session in claude.ai's Remote
    /// Control panel (and analogous systems if other agents support it).
    /// `autoPermissionMode` mirrors `ClaudeCodeAgent`'s `--permission-mode auto`
    /// — agents that don't surface this concept can ignore it. `telemetryPort`
    /// is passed through for consistency with `autoLaunchCommand`; most
    /// agents won't need it for Manager terminals (CROW-433).
    func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String
}

public extension CodingAgent {
    /// Default Manager launch command: invoke the agent's CLI binary by
    /// name with no extra flags. Agents with richer launch ergonomics
    /// (Claude Code's `--rc`/`--name`/`--permission-mode`) override this.
    func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        return "\(launchCommandToken)\n"
    }
}
