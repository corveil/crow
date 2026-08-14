import Foundation
import CrowCore

/// Translates Muse Code hook events into `AgentStateTransition` values.
///
/// Muse's documented lifecycle events are Claude-named (`SessionStart`,
/// `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`,
/// `Stop`, plus Muse-only LLM/compact/subagent events — official extending
/// docs, 2026-08-14). This source maps the subset `MuseHookConfigWriter`
/// actually registers, plus a defensive `PreToolUse` arm so a later
/// re-enable lights up with no further change.
///
/// **Version-pinned re-check target:** confirm empirically that `Stop` and
/// `PermissionRequest` fire on the transitions this machine needs. Muse is
/// closed-source; event semantics may differ from Claude's even when the
/// names match.
public struct MuseSignalSource: StateSignalSource {
    public init() {}

    public func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition {
        // Same blanket-clear policy as Claude/Cursor: every event except
        // `PermissionRequest` (which may *set* the pending notification
        // itself) clears any pending notification.
        let blanketClear = event.eventName != "PermissionRequest"
        var transition = AgentStateTransition(
            notification: blanketClear ? .clear : .leave
        )

        switch event.eventName {
        case "SessionStart":
            let source = event.source ?? "startup"
            transition.newActivityState = source == "resume" ? .done : .idle
            transition.lastTopLevelStopAt = .clear

        case "UserPromptSubmit":
            transition.newActivityState = .working
            transition.lastTopLevelStopAt = .clear

        case "PreToolUse":
            // Not registered by the current writer (stdout verdict unverified).
            // Kept for future-proofing.
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
            if currentLastTopLevelStopAt == nil {
                transition.newActivityState = .working
            }

        case "PermissionRequest":
            if currentNotificationType != "question" {
                transition.notification = .set(HookNotification(
                    message: event.message ?? "Permission requested",
                    notificationType: event.notificationType ?? "permission_prompt"
                ))
            }
            transition.newActivityState = .waiting
            transition.toolActivity = .clear

        case "Stop":
            transition.newActivityState = .done
            transition.toolActivity = .clear
            transition.lastTopLevelStopAt = .set(Date())

        default:
            // Unknown / future events (PreLLMCall, SubagentStop, …) get the
            // blanket notification clear and nothing else.
            break
        }

        return transition
    }
}
