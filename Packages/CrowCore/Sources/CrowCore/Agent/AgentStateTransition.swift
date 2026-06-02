import Foundation

/// A batch of per-session state changes produced by a `StateSignalSource` in
/// response to an `AgentHookEvent`. The hook-event RPC handler applies this
/// transition to `SessionHookState` — the signal source never touches state
/// itself, making the state machine testable in isolation.
public struct AgentStateTransition: Sendable {
    public enum NotificationUpdate: Sendable {
        case leave
        case clear
        case set(HookNotification)
    }

    public enum ToolActivityUpdate: Sendable {
        case leave
        case clear
        case set(ToolActivity)
    }

    public enum LastTopLevelStopAtUpdate: Sendable {
        case leave
        case clear
        case set(Date)
    }

    /// New activity state, or `nil` to leave the current state untouched.
    public var newActivityState: AgentActivityState?

    /// Whether/how to mutate `SessionHookState.pendingNotification`.
    public var notification: NotificationUpdate

    /// Whether/how to mutate `SessionHookState.lastToolActivity`.
    public var toolActivity: ToolActivityUpdate

    /// Whether/how to mutate `SessionHookState.lastTopLevelStopAt` — used to
    /// suppress activity-state elevation from background subagent work that
    /// fires after the user's turn has already ended.
    public var lastTopLevelStopAt: LastTopLevelStopAtUpdate

    public init(
        newActivityState: AgentActivityState? = nil,
        notification: NotificationUpdate = .leave,
        toolActivity: ToolActivityUpdate = .leave,
        lastTopLevelStopAt: LastTopLevelStopAtUpdate = .leave
    ) {
        self.newActivityState = newActivityState
        self.notification = notification
        self.toolActivity = toolActivity
        self.lastTopLevelStopAt = lastTopLevelStopAt
    }
}
