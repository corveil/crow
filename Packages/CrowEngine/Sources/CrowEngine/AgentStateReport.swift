import CrowCore
import CrowIPC
import Foundation

/// `agent_state`, `last_prompt_at` and `agent_terminal_id` for `get-session`
/// and `list-sessions` (CROW-1475).
///
/// Both RPCs call ``fields(for:appState:paneCommands:now:)`` so the two can
/// never disagree. The derivation itself is the pure ``AgentReadiness``.
@MainActor
public enum AgentStateReport {

    /// The session's agent pane: a work session's managed terminal, or a
    /// Manager's command terminal (Manager panes carry no `isManaged` flag).
    public static func agentTerminal(for session: Session, appState: AppState) -> SessionTerminal? {
        appState.terminals(for: session.id).first { $0.isAgentSurface(session: session) }
    }

    /// The derivation inputs for `session`. `paneCommands` is one
    /// ``TerminalRouter/paneCurrentCommands()`` read shared across sessions;
    /// nil means tmux couldn't answer, which disables only exit detection.
    public static func inputs(
        for session: Session, appState: AppState, paneCommands: [UUID: String]?
    ) -> AgentReadiness.Inputs {
        let terminal = agentTerminal(for: session, appState: appState)
        let hook = appState.existingHookState(for: session.id)
        return AgentReadiness.Inputs(
            hasAgentTerminal: terminal != nil,
            readiness: terminal.flatMap { appState.terminalReadiness[$0.id] },
            paneCommand: terminal.flatMap { paneCommands?[$0.id] },
            processExited: session.id == AppState.managerSessionID && appState.managerProcessExited,
            launchPending: hook?.agentLaunchPending ?? false,
            launchedAt: hook?.agentLaunchedAt,
            announcedAt: hook?.agentAnnouncedAt,
            activity: hook?.activityState ?? .idle,
            hasPendingNotification: hook?.pendingNotification != nil,
            turnEnded: hook?.lastTopLevelStopAt != nil)
    }

    /// The JSON fields. Each is always present: `null` when the session has
    /// no agent terminal (`agent_state`, `agent_terminal_id`) or no prompt has
    /// been seen since `crowd` started (`last_prompt_at`).
    public static func fields(
        for session: Session,
        appState: AppState,
        paneCommands: [UUID: String]?,
        now: Date = Date()
    ) -> [String: JSONValue] {
        let state = AgentReadiness.state(
            inputs(for: session, appState: appState, paneCommands: paneCommands), now: now)
        let lastPrompt = appState.existingHookState(for: session.id)?.lastPromptAt
        // Fractional seconds: `crow send --wait-ack` compares this before and
        // after a send, and two prompts can land in the same second.
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [
            "agent_state": state.map { .string($0.rawValue) } ?? .null,
            "last_prompt_at": lastPrompt.map { .string(fmt.string(from: $0)) } ?? .null,
            "agent_terminal_id": agentTerminal(for: session, appState: appState)
                .map { .string($0.id.uuidString) } ?? .null,
        ]
    }
}
