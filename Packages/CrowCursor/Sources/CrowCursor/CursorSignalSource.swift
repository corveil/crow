import Foundation
import CrowCore

/// Translates Cursor hook events into `AgentStateTransition` values.
///
/// Cursor's native event names are camelCase, but `CursorHookConfigWriter`
/// rewrites every event to its Crow-canonical PascalCase name in the
/// `--event` argument so this source can share Claude/Codex's vocabulary
/// verbatim: `SessionStart`, `PreToolUse`, `PostToolUse`,
/// `UserPromptSubmit`, `Stop`, `Notification`.
///
/// `Notification` here is mapped from Cursor's `afterAgentResponse` — a
/// safety net for headless `agent -p` mode where `stop` may not fire (one
/// of the three things to confirm empirically per the ticket). It clears
/// tool activity and transitions to `.done` only when we haven't already
/// recorded a `Stop`, so the canonical path isn't perturbed.
public struct CursorSignalSource: StateSignalSource {
    public init() {}

    public func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition {
        // Same blanket-clear policy as Claude/Codex: every event except
        // `PermissionRequest` clears the pending notification. We keep the
        // exclusion defensive even though the current writer doesn't
        // surface `PermissionRequest` directly — a follow-up that maps
        // Cursor's permission flow into this vocabulary will inherit the
        // correct precedence.
        let blanketClear = event.eventName != "PermissionRequest"
        var transition = AgentStateTransition(
            notification: blanketClear ? .clear : .leave
        )

        switch event.eventName {
        case "SessionStart":
            let source = event.source ?? "startup"
            transition.newActivityState = source == "resume" ? .done : .idle
            transition.lastTopLevelStopAt = .clear

        case "PreToolUse":
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: true
            ))
            transition.newActivityState = .working

        case "PostToolUse":
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: false
            ))

        case "UserPromptSubmit":
            transition.newActivityState = .working
            transition.lastTopLevelStopAt = .clear

        case "Stop":
            transition.newActivityState = .done
            transition.toolActivity = .clear
            transition.lastTopLevelStopAt = .set(Date())

        case "Notification":
            // Safety net for headless mode. Only flip to `.done` if we
            // haven't recorded a top-level Stop yet — when Stop has
            // already fired, a trailing Notification shouldn't override
            // its (more precise) timing or clear its toolActivity again.
            transition.toolActivity = .clear
            if currentLastTopLevelStopAt == nil {
                transition.newActivityState = .done
            }

        case "PermissionRequest":
            // Cursor's writer doesn't currently map a Cursor event to
            // `PermissionRequest`, but the case is kept for cross-agent
            // parity and for the follow-up that will route Cursor's
            // permission flow through here.
            if currentNotificationType != "question" {
                transition.notification = .set(HookNotification(
                    message: "Permission requested",
                    notificationType: "permission_prompt"
                ))
            }
            transition.newActivityState = .waiting
            transition.toolActivity = .clear

        default:
            // Unknown events get the blanket notification clear and
            // nothing else — Cursor's event vocabulary may grow over
            // time without requiring code changes for events that
            // don't change state.
            break
        }

        return transition
    }
}
