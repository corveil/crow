import Foundation

/// Translates raw agent runtime events (hook events today, other transports
/// later) into `AgentStateTransition` values. One implementation per agent.
///
/// Implementations must be pure: given the same inputs they produce the same
/// transition, with no external side effects. Side effects (persistence,
/// notifications, telemetry) are driven by the caller after applying the
/// transition.
public protocol StateSignalSource: Sendable {
    func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition
}
