import Foundation

/// User-facing notification event categories.
///
/// Two families:
///  - **Agent/PR events** mapped from raw Claude Code hook events + PR status polling.
///    Only events that require human attention trigger notifications. Most hook events
///    (e.g., tool execution, streaming responses) are intentionally unmapped — they fire
///    too frequently and don't need the user's immediate attention.
///  - **Automation events** — the moments Crow acts on your behalf (auto-workspace,
///    auto-merge, auto-rebase, config reload). These never arrive as hook events; the
///    daemon pushes them to clients at the point the watcher acts (CROW-768).
public enum NotificationEvent: String, Codable, Sendable, CaseIterable, Identifiable {
    case taskComplete
    case agentWaiting
    case reviewRequested
    case changesRequested
    case checksFailing
    // Automation events (CROW-768). Restored from the retired native
    // NotificationManager (ADR-0010); emitted by the daemon's watchers.
    case autoWorkspaceCreated
    case autoMergeEnabled
    case autoRebasePushed
    case autoRebaseConflicts
    case configReloaded

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .taskComplete: "Task Complete"
        case .agentWaiting: "Agent Waiting"
        case .reviewRequested: "Review Requested"
        case .changesRequested: "Changes Requested"
        case .checksFailing: "CI Failing"
        case .autoWorkspaceCreated: "Auto-Workspace Created"
        case .autoMergeEnabled: "Auto-Merge Enabled"
        case .autoRebasePushed: "Branch Rebased"
        case .autoRebaseConflicts: "Rebase Conflicts"
        case .configReloaded: "Config Reloaded"
        }
    }

    public var description: String {
        switch self {
        case .taskComplete: "Claude finished responding"
        case .agentWaiting: "Claude needs your input or permission"
        case .reviewRequested: "Someone requested your review on a PR"
        case .changesRequested: "A reviewer requested changes on your PR"
        case .checksFailing: "CI checks started failing on your PR"
        case .autoWorkspaceCreated: "Crow auto-created a workspace for an assigned issue"
        case .autoMergeEnabled: "Crow enabled auto-merge on a PR"
        case .autoRebasePushed: "Crow rebased a PR branch onto its base and pushed"
        case .autoRebaseConflicts: "An auto-rebase hit conflicts that need attention"
        case .configReloaded: "Crow reloaded its configuration"
        }
    }

    public var defaultSound: String {
        switch self {
        case .taskComplete: "Glass"
        case .agentWaiting: "Funk"
        case .reviewRequested: "Glass"
        case .changesRequested: "Funk"
        case .checksFailing: "Sosumi"
        case .autoWorkspaceCreated: "Hero"
        case .autoMergeEnabled: "Glass"
        case .autoRebasePushed: "Bottle"
        // Deliberately harsh, so a conflict is audibly distinct from the
        // success events it sits next to (CROW-768).
        case .autoRebaseConflicts: "Basso"
        case .configReloaded: "Tink"
        }
    }

    /// Whether this event is one Crow's own automation emits (as opposed to an
    /// agent hook / PR-status transition). Automation events are pushed by the
    /// daemon and always carry their own notification body.
    public var isAutomationEvent: Bool {
        switch self {
        case .autoWorkspaceCreated, .autoMergeEnabled, .autoRebasePushed,
             .autoRebaseConflicts, .configReloaded:
            true
        case .taskComplete, .agentWaiting, .reviewRequested, .changesRequested, .checksFailing:
            false
        }
    }

    /// Map a raw hook event name to a notification category.
    /// Returns `nil` for events that don't require human attention.
    ///
    /// - Parameters:
    ///   - eventName: The raw hook event name (e.g. "Stop", "PermissionRequest").
    ///   - toolName: The tool name from the payload, if applicable (e.g. "AskUserQuestion").
    ///   - notificationType: The notification type from the payload, if applicable (e.g. "permission_prompt").
    public static func from(
        eventName: String,
        toolName: String? = nil,
        notificationType: String? = nil
    ) -> NotificationEvent? {
        switch eventName {
        case "Stop":
            return .taskComplete

        case "PreToolUse":
            if toolName == "AskUserQuestion" { return .agentWaiting }
            return nil

        case "PermissionRequest":
            return .agentWaiting

        case "Notification":
            if notificationType == "permission_prompt" { return .agentWaiting }
            return nil

        default:
            return nil
        }
    }
}
