import Foundation
import CrowCore

/// Translates OpenAI Codex hook events into `AgentStateTransition` values.
/// Codex uses Claude Code's hook engine internally (verified empirically
/// against `codex` 0.123.0 — `ClaudeHooksEngine` is referenced in the binary
/// and the input schemas are byte-compatible), so the payload keys are the
/// same and the state transitions mirror the Claude side for the events
/// Codex emits.
///
/// Codex emits 6 hook events: `SessionStart`, `PreToolUse`, `PostToolUse`,
/// `UserPromptSubmit`, `Stop`, `PermissionRequest`. No `Notification`,
/// `SubagentStart`, `TaskCreated`, `TaskCompleted`, or other Claude-only
/// events.
///
/// `currentLastTopLevelStopAt` is tracked for protocol consistency (Stop
/// sets it; UserPromptSubmit / SessionStart clear it) but isn't read by any
/// transition — Codex doesn't have an analog of Claude's
/// `awaySummaryEnabled` recap subagent that would fire post-Stop.
public struct CodexSignalSource: StateSignalSource {
    public init() {}

    public func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition {
        // Same blanket-clear policy as Claude: every event except
        // `PermissionRequest` clears the pending notification (Codex doesn't
        // emit `Notification` events, so it's not in the exclusion list).
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

        case "PermissionRequest":
            // Same precedence rule as Claude — don't override a prior
            // "question" notification (Codex doesn't actually emit AskUserQuestion,
            // so this is mostly defensive, kept for cross-agent parity).
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
            // else — Codex's event vocabulary may grow over time without
            // requiring code changes for events that don't change state.
            break
        }

        return transition
    }
}
