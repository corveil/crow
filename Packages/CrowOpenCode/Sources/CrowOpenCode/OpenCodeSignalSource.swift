import Foundation
import CrowCore

/// Translates OpenCode hook events into `AgentStateTransition` values.
///
/// `OpenCodeHookConfigWriter`'s plugin rewrites every OpenCode event to its
/// Crow-canonical PascalCase name in the `--event` argument, so this source
/// shares Claude/Codex/Cursor's vocabulary verbatim: `SessionStart`,
/// `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `Notification`,
/// `PermissionRequest`. The MVP plugin only emits a subset (no
/// `UserPromptSubmit`); the extra cases are kept for cross-agent parity and
/// to absorb events a future plugin revision may add without code changes.
///
/// The mapping is intentionally identical to `CursorSignalSource` — OpenCode
/// and Cursor are both TUI agents whose state model (idle ⇄ working ⇄ waiting)
/// is the same; only the transport (JS plugin vs `hooks.json`) differs.
public struct OpenCodeSignalSource: StateSignalSource {
    public init() {}

    public func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition {
        // Same blanket-clear policy as Claude/Codex/Cursor: every event
        // except `PermissionRequest` clears the pending notification.
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
            // Safety net (e.g. `session.error`). Only flip to `.done` if we
            // haven't recorded a top-level Stop yet, so a trailing
            // Notification doesn't override Stop's (more precise) timing.
            transition.toolActivity = .clear
            if currentLastTopLevelStopAt == nil {
                transition.newActivityState = .done
            }

        case "PermissionRequest":
            // OpenCode's `permission.asked` maps here — the agent is blocked
            // waiting on a user decision.
            if currentNotificationType != "question" {
                transition.notification = .set(HookNotification(
                    message: "Permission requested",
                    notificationType: "permission_prompt"
                ))
            }
            transition.newActivityState = .waiting
            transition.toolActivity = .clear

        default:
            // Unknown events get the blanket notification clear and nothing
            // else — OpenCode's event vocabulary may grow without requiring
            // code changes for events that don't change state.
            break
        }

        return transition
    }
}
