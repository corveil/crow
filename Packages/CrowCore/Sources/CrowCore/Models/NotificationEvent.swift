import Foundation

/// User-facing notification event categories.
///
/// Two families:
///  - **Agent/PR events** mapped from raw Claude Code hook events + PR status polling.
///    Only events that require human attention trigger notifications. Most hook events
///    (e.g., tool execution, streaming responses) are intentionally unmapped — they fire
///    too frequently and don't need the user's immediate attention.
///  - **Automation events** — the moments Crow acts on your behalf (auto-workspace,
///    auto-merge, auto-rebase, config reload), plus a launch-time warning Crow raises
///    itself (`claudeOutsideReadsBlocked`, CROW-1527). These never arrive as hook
///    events; the daemon pushes them to clients at the point it acts (CROW-768).
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
    // The counterpart to `autoMergeEnabled`: the watcher looked at a
    // `crow:merge` PR and concluded it will never merge it (#888). Permanent
    // skips are latched, so this is the ONLY channel besides the log file —
    // there is no later poll to notice it.
    case autoMergeBlocked
    case autoRebasePushed
    case autoRebaseConflicts
    /// The third auto-rebase outcome, and the one with no automated next step
    /// (#944). A conflict hands off to the agent; a *stuck* rebase can't —
    /// the worktree is dirty, or the branch holds commits `origin` doesn't and
    /// any force-push would destroy them. Crow keeps retrying at the backoff
    /// cap, so without a notification this state repeats in the log forever and
    /// surfaces nowhere. Fires at most once per (PR, reason).
    case autoRebaseStuck
    /// A Claude auto-mode session launched with
    /// `permissions.blockReadsOutsideWorkingDirectories` on (CROW-1527). Since
    /// Claude Code 2.1.327 its outside-path Bash commands wait on an approval
    /// dialog, which an unattended session never answers. Fires once per
    /// session and settings file; Crow only reports the setting, never changes it.
    case claudeOutsideReadsBlocked
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
        case .autoMergeBlocked: "Auto-Merge Blocked"
        case .autoRebasePushed: "Branch Rebased"
        case .autoRebaseConflicts: "Rebase Conflicts"
        case .autoRebaseStuck: "Rebase Stuck"
        case .claudeOutsideReadsBlocked: "Claude Outside Reads Blocked"
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
        case .autoMergeBlocked: "Crow can't auto-merge a crow:merge PR and has stopped trying"
        case .autoRebasePushed: "Crow rebased a PR branch onto its base and pushed"
        case .autoRebaseConflicts: "An auto-rebase hit conflicts that need attention"
        case .autoRebaseStuck: "An auto-rebase can't proceed and needs you"
        case .claudeOutsideReadsBlocked: "A Claude auto-mode session will wait for approval on outside-path commands"
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
        // success events it sits next to (CROW-768). `autoMergeBlocked` joins
        // it for the same reason: it is the one auto-merge event that means
        // "Crow stopped and needs you", not "Crow handled it" (#888).
        // `autoRebaseStuck` is that same family — Crow is still retrying, but
        // only a human changes the outcome (#944).
        case .autoRebaseConflicts, .autoMergeBlocked, .autoRebaseStuck: "Basso"
        // The "may need you later" sound, same as `agentWaiting`: the stall it
        // warns about is an approval dialog.
        case .claudeOutsideReadsBlocked: "Funk"
        case .configReloaded: "Tink"
        }
    }

    /// Whether this event speaks when spoken notifications are on and the user
    /// hasn't overridden it. Off for the routine, high-frequency successes
    /// (a rebase that just worked, a config reload) so turning voice on doesn't
    /// narrate background chores; on for anything that wants a human.
    public var defaultVoiceEnabled: Bool {
        switch self {
        case .autoRebasePushed, .autoMergeEnabled, .configReloaded: false
        default: true
        }
    }

    /// The sentence spoken for this event. Placeholders (`{session}`, `{repo}`,
    /// `{pr}`, `{event}`, `{title}`, `{body}`) are filled in by the client from
    /// the same data the banner uses. Short on purpose — it is heard, not read.
    public var defaultVoiceTemplate: String {
        switch self {
        case .taskComplete: "{session} is done"
        case .agentWaiting: "{session} needs you"
        case .reviewRequested: "Review requested on {repo}"
        case .changesRequested: "Changes requested on {session}"
        case .checksFailing: "CI failing on {session}"
        case .autoWorkspaceCreated: "{title}"
        case .autoMergeEnabled: "Auto-merge enabled on {session}"
        case .autoMergeBlocked: "Auto-merge blocked on {session}"
        case .autoRebasePushed: "{session} was rebased"
        case .autoRebaseConflicts: "Rebase conflicts on {session}"
        case .autoRebaseStuck: "Rebase stuck on {session}"
        case .claudeOutsideReadsBlocked: "{session} may stall on approvals"
        case .configReloaded: "Config reloaded"
        }
    }

    /// Whether this event is one Crow's own automation emits (as opposed to an
    /// agent hook / PR-status transition). Automation events are pushed by the
    /// daemon and always carry their own notification body.
    public var isAutomationEvent: Bool {
        switch self {
        case .autoWorkspaceCreated, .autoMergeEnabled, .autoMergeBlocked, .autoRebasePushed,
             .autoRebaseConflicts, .autoRebaseStuck, .claudeOutsideReadsBlocked, .configReloaded:
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
