import Foundation
import Testing
@testable import CrowCore

@Test func notificationEventAllCasesCount() {
    // 5 agent/PR events + 5 automation events (CROW-768).
    #expect(NotificationEvent.allCases.count == 10)
}

@Test func notificationEventDefaultSoundsNonEmpty() {
    for event in NotificationEvent.allCases {
        #expect(!event.defaultSound.isEmpty)
    }
}

@Test func notificationEventDisplayNamesNonEmpty() {
    for event in NotificationEvent.allCases {
        #expect(!event.displayName.isEmpty)
        #expect(!event.description.isEmpty)
    }
}

// MARK: - from() mapping

@Test func fromStopMapsToTaskComplete() {
    #expect(NotificationEvent.from(eventName: "Stop") == .taskComplete)
}

@Test func fromPreToolUseAskUserQuestionMapsToAgentWaiting() {
    #expect(NotificationEvent.from(eventName: "PreToolUse", toolName: "AskUserQuestion") == .agentWaiting)
}

@Test func fromPreToolUseOtherToolReturnsNil() {
    #expect(NotificationEvent.from(eventName: "PreToolUse", toolName: "Bash") == nil)
    #expect(NotificationEvent.from(eventName: "PreToolUse") == nil)
}

@Test func fromPermissionRequestMapsToAgentWaiting() {
    #expect(NotificationEvent.from(eventName: "PermissionRequest") == .agentWaiting)
}

@Test func fromNotificationPermissionPromptMapsToAgentWaiting() {
    #expect(NotificationEvent.from(eventName: "Notification", notificationType: "permission_prompt") == .agentWaiting)
}

@Test func fromNotificationOtherTypeReturnsNil() {
    #expect(NotificationEvent.from(eventName: "Notification", notificationType: "info") == nil)
    #expect(NotificationEvent.from(eventName: "Notification") == nil)
}

@Test func fromUnknownEventReturnsNil() {
    #expect(NotificationEvent.from(eventName: "Start") == nil)
    #expect(NotificationEvent.from(eventName: "PostToolUse") == nil)
    #expect(NotificationEvent.from(eventName: "") == nil)
}

// MARK: - Codable round-trip

@Test func notificationEventCodableRoundTrip() throws {
    for event in NotificationEvent.allCases {
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(NotificationEvent.self, from: data)
        #expect(decoded == event)
    }
}

// MARK: - PR transition events

@Test func changesRequestedAndChecksFailingArePresent() {
    #expect(NotificationEvent.allCases.contains(.changesRequested))
    #expect(NotificationEvent.allCases.contains(.checksFailing))
}

@Test func prTransitionEventsHaveDistinctDefaultSounds() {
    // Different default sounds so the two events are audibly distinct.
    #expect(NotificationEvent.changesRequested.defaultSound != NotificationEvent.checksFailing.defaultSound)
}

// MARK: - Automation events (CROW-768)

@Test func automationEventsArePresentAndClassified() {
    let automation: [NotificationEvent] = [
        .autoWorkspaceCreated, .autoMergeEnabled, .autoRebasePushed,
        .autoRebaseConflicts, .configReloaded,
    ]
    for event in automation {
        #expect(NotificationEvent.allCases.contains(event))
        #expect(event.isAutomationEvent)
    }
    // Everything else is derived from hooks / PR polling, not pushed.
    for event in NotificationEvent.allCases where !automation.contains(event) {
        #expect(!event.isAutomationEvent)
    }
}

@Test func automationEventsNeverArriveAsHookEvents() {
    // `from` maps raw Claude Code hook names; automation events are pushed by the
    // daemon's watchers and must not be reachable through that mapper.
    for event in NotificationEvent.allCases where event.isAutomationEvent {
        #expect(NotificationEvent.from(eventName: event.rawValue) == nil)
    }
}

@Test func rebaseConflictsSoundsDistinctFromRebaseSuccess() {
    // Acceptance criterion: an attention event must be audibly distinguishable
    // from the success event beside it.
    #expect(NotificationEvent.autoRebaseConflicts.defaultSound
            != NotificationEvent.autoRebasePushed.defaultSound)
}
