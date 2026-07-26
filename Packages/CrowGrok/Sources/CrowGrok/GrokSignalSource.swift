import Foundation
import CrowCore

/// Translates Grok Build hook events into `AgentStateTransition` values.
///
/// Grok's hook schema is Claude/Cursor-compatible (verified against
/// `xai-org/grok-build@main`, 2026-07-25 — `crates/codegen/xai-grok-hooks`),
/// so the payload keys are the same and the transitions mirror the Claude side
/// for the events Grok emits. This source shares Claude/Codex/Cursor/OpenCode's
/// canonical PascalCase vocabulary verbatim.
///
/// `GrokHookConfigWriter` registers these events (all verified in
/// `xai-grok-hooks/src/event.rs`):
///   SessionStart       → active (fresh) / done (resume)
///   UserPromptSubmit   → working (a real turn began)
///   PreToolUse         → working + tool active
///   PostToolUse        → tool inactive
///   PostToolUseFailure → tool inactive
///   Notification       → waiting (agent is blocked on the user)
///   Stop               → done (a genuine turn-end; Grok has a real `Stop`
///                        gate, unlike Gemini's done-proxy)
///   StopFailure        → waiting (turn ended on an API error)
///   SessionEnd         → idle
///
/// **Version-pinned re-check target (#859):** confirm empirically that `Stop`
/// and `Notification` fire on the transitions this machine needs. Grok's repo
/// is a periodic mirror of xAI's monorepo, closed to external PRs, so event
/// names/semantics may churn — re-probe on each upstream sync.
public struct GrokSignalSource: StateSignalSource {
    public init() {}

    public func transition(
        for event: AgentHookEvent,
        currentActivityState: AgentActivityState,
        currentNotificationType: String?,
        currentLastTopLevelStopAt: Date?
    ) -> AgentStateTransition {
        // Same blanket-clear policy as Claude/Codex/Cursor/OpenCode: every event
        // except `Notification` (which may *set* the pending notification
        // itself) clears any pending notification.
        let blanketClear = event.eventName != "Notification"
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
            // A new real turn has begun — clear the post-Stop guard.
            transition.lastTopLevelStopAt = .clear

        case "PreToolUse":
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: true
            ))
            transition.newActivityState = .working

        case "PostToolUse", "PostToolUseFailure":
            let toolName = event.toolName ?? "unknown"
            transition.toolActivity = .set(ToolActivity(
                toolName: toolName, isActive: false
            ))

        case "Notification":
            // Grok fires `Notification` when it needs the user (permission
            // prompt / idle-at-prompt). Surface it as "awaiting input". The
            // message/type come straight off the event payload.
            let message = event.message ?? "Grok needs your input"
            let notifType = event.notificationType ?? "notification"
            transition.notification = .set(HookNotification(
                message: message, notificationType: notifType
            ))
            transition.newActivityState = .waiting
            transition.toolActivity = .clear

        case "Stop":
            transition.newActivityState = .done
            transition.toolActivity = .clear
            transition.lastTopLevelStopAt = .set(Date())

        case "StopFailure":
            transition.newActivityState = .waiting
            transition.lastTopLevelStopAt = .set(Date())

        case "SessionEnd":
            transition.newActivityState = .idle
            transition.toolActivity = .clear
            transition.lastTopLevelStopAt = .clear

        default:
            // Unknown events get the blanket notification clear and nothing
            // else — Grok's event vocabulary may grow (or churn) upstream
            // without requiring code changes for events that don't change state.
            break
        }

        return transition
    }
}
