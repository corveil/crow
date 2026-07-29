import Foundation
import CrowCore

/// Translates Claude Code hook events into `AgentStateTransition` values.
/// This is the state machine that AppDelegate used to embed inline; moving it
/// here keeps the per-agent behavior next to `ClaudeHookConfigWriter` and lets
/// the hook-event handler stay small.
///
/// Pure: returns a transition, never mutates shared state. Callers apply the
/// transition to `SessionHookState` after receiving it.
public struct ClaudeHookSignalSource: StateSignalSource {
    public init() {}

    public func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition {
        // Most events clear any pending notification. Notification and
        // PermissionRequest are the two cases that may *set* the pending
        // notification themselves, so we don't preemptively clear for them.
        let blanketClear = event.eventName != "Notification"
            && event.eventName != "PermissionRequest"
        var transition = AgentStateTransition(
            notification: blanketClear ? .clear : .leave
        )

        switch event.eventName {
        case "PreToolUse":
            let toolName = event.toolName ?? "unknown"
            if toolName == "AskUserQuestion" {
                transition.notification = .set(HookNotification(
                    message: "Claude has a question",
                    notificationType: "question"
                ))
                transition.newActivityState = .waiting
                transition.toolActivity = .clear
            } else {
                transition.toolActivity = .set(ToolActivity(
                    toolName: toolName, isActive: true
                ))
                transition.newActivityState = .working
            }

        case "PostToolUse":
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: false
            ))

        case "PostToolUseFailure":
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: false
            ))

        case "Notification":
            let message = event.message ?? ""
            let notifType = event.notificationType ?? ""
            if notifType == "permission_prompt" {
                transition.notification = .set(HookNotification(
                    message: message, notificationType: notifType
                ))
                transition.newActivityState = .waiting
            } else if notifType == "idle_prompt" {
                // At the prompt — clear any stale permission notification.
                // Don't change activity state (Stop already set it to .done).
                transition.notification = .clear
            }

        case "PermissionRequest":
            // Don't override a "question" notification — AskUserQuestion
            // triggers both PreToolUse and PermissionRequest, and the question
            // badge is more specific than generic "Permission".
            if currentNotificationType != "question" {
                transition.notification = .set(HookNotification(
                    message: "Permission requested",
                    notificationType: "permission_prompt"
                ))
            }
            transition.newActivityState = .waiting
            transition.toolActivity = .clear

        case "UserPromptSubmit":
            transition.newActivityState = .working
            // A new real turn has begun — clear the post-Stop guard so
            // legitimate subagents in this turn can elevate state again.
            transition.lastTopLevelStopAt = .clear

        case "Stop":
            transition.newActivityState = .done
            transition.toolActivity = .clear
            transition.lastTopLevelStopAt = .set(Date())

        case "StopFailure":
            transition.newActivityState = .waiting
            transition.lastTopLevelStopAt = .set(Date())

        case "SessionStart":
            let source = event.source ?? "startup"
            if source == "resume" {
                transition.newActivityState = .done
            } else {
                transition.newActivityState = .idle
            }
            transition.lastTopLevelStopAt = .clear

        case "SessionEnd":
            transition.newActivityState = .idle
            transition.toolActivity = .clear
            transition.lastTopLevelStopAt = .clear

        case "SubagentStart":
            // If a top-level Stop has already fired for this turn, the
            // subagent is background work (e.g. the recap generator from
            // Claude Code ≥ 2.1.108's awaySummaryEnabled feature). Don't
            // elevate state — the user is genuinely done.
            if currentLastTopLevelStopAt == nil {
                transition.newActivityState = .working
            }

        case "TaskCreated", "TaskCompleted", "SubagentStop":
            // Stay in working state, but only while the turn is still live.
            // After a top-level Stop, treat these as background activity
            // and leave the activity state alone. Also don't clobber a
            // pending question/permission.
            if currentActivityState != .waiting && currentLastTopLevelStopAt == nil {
                transition.newActivityState = .working
            }

        case "PermissionDenied":
            transition.newActivityState = .working
            transition.toolActivity = .clear

        default:
            // PreCompact, PostCompact, and any unknown event just get the
            // blanket notification clear applied above.
            break
        }

        return transition
    }
}
