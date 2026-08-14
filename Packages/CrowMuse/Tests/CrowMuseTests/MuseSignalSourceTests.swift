import Foundation
import Testing
@testable import CrowMuse
@testable import CrowCore

@Suite("MuseSignalSource")
struct MuseSignalSourceTests {
    private let source = MuseSignalSource()

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

    @Test func postToolUseMarksInactiveAndWorking() {
        let t = source.transition(
            for: event("PostToolUse", toolName: "Bash"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .working)
        if case .set(let activity) = t.toolActivity {
            #expect(activity.toolName == "Bash")
            #expect(activity.isActive == false)
        } else {
            Issue.record("expected tool activity set inactive")
        }
    }

    @Test func permissionRequestMarksWaiting() {
        let t = source.transition(
            for: event("PermissionRequest", message: "Allow gh?"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
        if case .set(let notif) = t.notification {
            #expect(notif.message == "Allow gh?")
            #expect(notif.notificationType == "permission_prompt")
        } else {
            Issue.record("expected permission notification")
        }
    }

    @Test func stopMarksDone() {
        let t = source.transition(
            for: event("Stop"),
            currentActivityState: .working,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
        if case .clear = t.toolActivity {} else {
            Issue.record("Stop should clear tool activity")
        }
        if case .set = t.lastTopLevelStopAt {} else {
            Issue.record("Stop should set the post-Stop guard")
        }
    }

    @Test func unknownEventClearsNotificationOnly() {
        let t = source.transition(
            for: event("PreLLMCall"),
            currentActivityState: .working,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil)
        if case .clear = t.notification {} else {
            Issue.record("unknown events should blanket-clear the notification")
        }
    }
}
