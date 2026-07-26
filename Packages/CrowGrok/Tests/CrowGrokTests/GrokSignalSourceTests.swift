import Foundation
import Testing
@testable import CrowGrok
@testable import CrowCore

@Suite("GrokSignalSource")
struct GrokSignalSourceTests {
    private let source = GrokSignalSource()

    private func event(
        _ name: String,
        toolName: String? = nil,
        source: String? = nil,
        message: String? = nil,
        notificationType: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: UUID(),
            eventName: name,
            toolName: toolName,
            source: source,
            message: message,
            notificationType: notificationType,
            summary: name
        )
    }

    @Test func sessionStartFreshMarksIdle() {
        let t = source.transition(
            for: event("SessionStart", source: "startup"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .idle)
    }

    @Test func sessionStartResumeMarksDone() {
        let t = source.transition(
            for: event("SessionStart", source: "resume"),
            currentActivityState: .idle,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
    }

    @Test func userPromptSubmitStartsWorkingAndClearsGuard() {
        let t = source.transition(
            for: event("UserPromptSubmit"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == .working)
        if case .clear = t.lastTopLevelStopAt {} else {
            Issue.record("UserPromptSubmit should clear the post-Stop guard")
        }
    }

    @Test func preToolUseSetsWorking() {
        let t = source.transition(
            for: event("PreToolUse", toolName: "Bash"),
            currentActivityState: .idle,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .working)
        if case .set(let activity) = t.toolActivity {
            #expect(activity.toolName == "Bash")
            #expect(activity.isActive == true)
        } else {
            Issue.record("expected tool activity set active")
        }
    }

    @Test func postToolUseMarksInactive() {
        let t = source.transition(
            for: event("PostToolUse", toolName: "Bash"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil)
        if case .set(let activity) = t.toolActivity {
            #expect(activity.isActive == false)
        } else {
            Issue.record("expected inactive tool activity")
        }
    }

    @Test func postToolUseFailureMarksInactive() {
        let t = source.transition(
            for: event("PostToolUseFailure", toolName: "Bash"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        if case .set(let activity) = t.toolActivity {
            #expect(activity.isActive == false)
        } else {
            Issue.record("expected inactive tool activity")
        }
    }

    @Test func notificationWaitsAndSetsNotification() {
        let t = source.transition(
            for: event("Notification", message: "Approve?", notificationType: "permission_prompt"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
        if case .set(let n) = t.notification {
            #expect(n.notificationType == "permission_prompt")
            #expect(n.message == "Approve?")
        } else {
            Issue.record("expected notification set")
        }
        if case .clear = t.toolActivity {} else {
            Issue.record("expected tool activity cleared")
        }
    }

    @Test func stopMarksDoneAndRecordsStop() {
        let t = source.transition(
            for: event("Stop"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
        if case .set = t.lastTopLevelStopAt {} else {
            Issue.record("Stop should record lastTopLevelStopAt")
        }
    }

    @Test func stopFailureWaits() {
        let t = source.transition(
            for: event("StopFailure"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
    }

    @Test func sessionEndMarksIdleAndClearsActivity() {
        let t = source.transition(
            for: event("SessionEnd"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .idle)
        if case .clear = t.toolActivity {} else {
            Issue.record("expected activity cleared")
        }
    }

    @Test func nonNotificationEventClearsPendingNotification() {
        let t = source.transition(
            for: event("UserPromptSubmit"),
            currentActivityState: .waiting,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        if case .clear = t.notification {} else {
            Issue.record("expected blanket clear for non-Notification event")
        }
    }

    @Test func unknownEventAppliesBlanketClearOnly() {
        let t = source.transition(
            for: event("SubagentStart"),
            currentActivityState: .working,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil)
        if case .clear = t.notification {} else {
            Issue.record("expected clear")
        }
    }
}
