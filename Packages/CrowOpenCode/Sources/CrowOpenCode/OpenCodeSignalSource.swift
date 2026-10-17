import Foundation
import CrowCore

/// Translates OpenCode hook events into `AgentStateTransition` values.
///
/// `OpenCodeHookConfigWriter`'s plugin rewrites every OpenCode event to its
/// Crow-canonical PascalCase name in the `--event` argument, so this source
/// shares Claude/Codex/Cursor's vocabulary verbatim: `SessionStart`,
/// `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `Notification`,
/// `PermissionRequest`. `UserPromptSubmit` and `Stop` are the two edges of a
/// turn: OpenCode 1's `session.status` (`busy` / `idle`, CROW-1000), or OpenCode
/// 2's `session.execution.started` / `.succeeded|failed|interrupted`
/// (CROW-1332). The one OpenCode-only name is `BridgeUnavailable`, the V2
/// plugin's fail-closed signal (below); the extra cases are kept for
/// cross-agent parity and to absorb events a future plugin revision adds
/// without code changes.
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
        // except `PermissionRequest` (and the bridge-failure signal, which sets
        // its own) clears the pending notification.
        let blanketClear = event.eventName != "PermissionRequest"
            && event.eventName != "BridgeUnavailable"
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
            // OpenCode's `permission.ask` hook maps here — the agent is blocked
            // waiting on a user decision.
            if currentNotificationType != "question" {
                transition.notification = .set(HookNotification(
                    message: "Permission requested",
                    notificationType: "permission_prompt"
                ))
            }
            transition.newActivityState = .waiting
            transition.toolActivity = .clear

        case "BridgeUnavailable":
            // The V2 plugin loaded but cannot observe the session (no event
            // stream, or it died) — so no `Stop` will ever arrive (CROW-1332).
            // Ask for attention instead of leaving a card that looks healthy.
            // Never `.done`: for a job, `.done` is completion (ADR 0015), and a
            // bridge failure is not the agent finishing.
            transition.notification = .set(HookNotification(
                message: event.message ?? "OpenCode state bridge unavailable",
                notificationType: "bridge_unavailable"
            ))
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
