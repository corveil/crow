import Foundation
import CrowCore

/// Translates Google Antigravity (`agy`) hook events into
/// `AgentStateTransition` values. Antigravity's hook *transport* is Claude-like
/// (JSON on stdin, JSON verdict on stdout) but its config schema is its own
/// (named groups — see `AntigravityHookConfigWriter`); this state machine only
/// cares about the flattened event name + tool name, so it stays close to
/// `ClaudeHookSignalSource` / `CursorSignalSource` (#860).
///
/// **`Stop` is the canonical "done" signal.** Antigravity's `Stop` hook carries
/// `fullyIdle` + `terminationReason` (`model_stop` / `max_steps_exceeded` /
/// `error`) in its stdin payload — a real idle marker, the strongest reason to
/// integrate via hooks. The pinned `AgentHookEvent` schema doesn't surface those
/// extra fields, so `Stop` firing ⇒ `.done`; refining on `terminationReason`
/// (e.g. mapping `error` to a distinct state) is a version-pinned follow-up.
///
/// **Events actually driven by the writer:** `PreInvocation` (turn start →
/// working), `PostInvocation` (observational), `PostToolUse` (tool activity),
/// `Stop` (done). `PreToolUse` is **not registered** by
/// `AntigravityHookConfigWriter` (its strict stdout decision gate is unsafe for
/// an observational hook — see that type), so tool activity is detected on
/// completion via `PostToolUse` rather than on start. The `PreToolUse` case
/// below is kept for cross-agent parity / future-proofing, not because the
/// current writer emits it — same posture as the defensive `PermissionRequest`
/// case (Antigravity has no awaiting-input hook on v1.1.7).
public struct AntigravitySignalSource: StateSignalSource {
    public init() {}

    public func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition {
        // Same blanket-clear policy as Claude/Cursor/Codex: every event except
        // `PermissionRequest` clears any pending notification. Kept defensive
        // even though the current writer doesn't surface `PermissionRequest`.
        let blanketClear = event.eventName != "PermissionRequest"
        var transition = AgentStateTransition(
            notification: blanketClear ? .clear : .leave
        )

        switch event.eventName {
        case "PreInvocation":
            // A new model invocation (turn) is starting — the analogue of
            // Claude's `UserPromptSubmit`. Elevate to working and clear the
            // post-Stop guard so this turn's tool activity can drive state.
            transition.newActivityState = .working
            transition.lastTopLevelStopAt = .clear

        case "PostInvocation":
            // The model invocation returned. Observational only: `Stop` is the
            // authoritative "done" signal (it carries `fullyIdle`), and a
            // multi-step turn can emit several invocations before genuinely
            // idling, so flipping to `.done` here would report done too early.
            // Blanket clear already applied; leave activity untouched.
            break

        case "PreToolUse":
            // NOT registered by the current writer (its stdout decision gate is
            // unsafe for observational hooks — see AntigravityHookConfigWriter).
            // Kept for cross-agent parity / future-proofing: if a later version
            // registers it, tool-start detection works with no further change.
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: true
            ))
            transition.newActivityState = .working

        case "PostToolUse":
            // Where tool activity is actually detected (since PreToolUse is off).
            // Records the tool that just ran; state stays whatever PreInvocation
            // set (working) until Stop — mirrors Cursor's observational
            // PostToolUse (no activity-state change here).
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: false
            ))

        case "Stop":
            transition.newActivityState = .done
            transition.toolActivity = .clear
            transition.lastTopLevelStopAt = .set(Date())

        case "PermissionRequest":
            // Not emitted by the current writer (Antigravity has no dedicated
            // awaiting-input hook on v1.1.7); kept for cross-agent parity and
            // the follow-up that maps `request-review` / `statusLine` here.
            if currentNotificationType != "question" {
                transition.notification = .set(HookNotification(
                    message: "Permission requested",
                    notificationType: "permission_prompt"
                ))
            }
            transition.newActivityState = .waiting
            transition.toolActivity = .clear

        default:
            // Unknown / future events get the blanket notification clear and
            // nothing else, so Antigravity's event vocabulary can grow without
            // code changes for events that don't move Crow's state.
            break
        }

        return transition
    }
}
