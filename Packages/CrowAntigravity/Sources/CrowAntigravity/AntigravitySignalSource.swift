import Foundation
import CrowCore

/// Translates Google Antigravity (`agy`) hook events into
/// `AgentStateTransition` values. Antigravity ships Claude-Code-style hooks —
/// JSON on stdin, reply on stdout, the same `PreToolUse`/`PostToolUse` tool
/// vocabulary — so this state machine is a near-clone of
/// `ClaudeHookSignalSource` / `CursorSignalSource`, differing only in the
/// invocation-level events Antigravity adds (`PreInvocation` / `PostInvocation`)
/// in place of Claude's `UserPromptSubmit` / `SessionStart` pair (#860).
///
/// **`Stop` is the canonical "done" signal.** Antigravity's `Stop` hook carries
/// `fullyIdle` + `terminationReason` (`model_stop` / `max_steps_exceeded` /
/// `error`) in its stdin payload — a real, reliable idle marker, which is what
/// makes hooks Antigravity's single strongest integration point. The pinned
/// `AgentHookEvent` schema doesn't surface those extra fields (they're not in
/// the flattened struct), so here `Stop` firing at all ⇒ `.done`; the
/// `fullyIdle`/`terminationReason` refinement (e.g. mapping `error` to a
/// distinct state) is a version-pinned follow-up. Matching Claude/Cursor, the
/// bare `Stop` → `.done` transition already satisfies Crow's active→done
/// contract.
///
/// **No awaiting-input event.** Antigravity has no dedicated "needs input" hook
/// on this version, so — unlike Claude's `PermissionRequest`/`Notification`
/// flow — this source never sets a `.waiting` notification. A `PermissionRequest`
/// case is kept for cross-agent parity (and the follow-up that would map
/// Antigravity's `request-review` mode / `statusLine` payload into it), but the
/// writer doesn't currently emit it.
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
