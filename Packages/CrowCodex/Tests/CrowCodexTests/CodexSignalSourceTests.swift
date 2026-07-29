import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("CodexSignalSource")
struct CodexSignalSourceTests {
    private let source = CodexSignalSource()

    private func event(
        _ name: String,
        toolName: String? = nil,
        source: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: UUID(),
            eventName: name,
            toolName: toolName,
            source: source,
            summary: name
        )
    }

    // MARK: - The 6 events Codex emits

    @Test func sessionStartFreshIdle() {
        let t = source.transition(
            for: event("SessionStart", source: "startup"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == .idle)
        if case .clear = t.lastTopLevelStopAt {} else {
            Issue.record("SessionStart should clear lastTopLevelStopAt")
        }
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

    @Test func userPromptSubmitClearsLastStopAt() {
        let t = source.transition(
            for: event("UserPromptSubmit"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == .working)
        if case .clear = t.lastTopLevelStopAt {} else {
            Issue.record("UserPromptSubmit should clear lastTopLevelStopAt")
        }
    }

    @Test func stopSetsLastStopAt() {
        let t = source.transition(
            for: event("Stop"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
        if case .clear = t.toolActivity {} else {
            Issue.record("Stop should clear tool activity")
        }
        if case .set = t.lastTopLevelStopAt {} else {
            Issue.record("Stop should set lastTopLevelStopAt")
        }
    }

    @Test func permissionRequestWaits() {
        let t = source.transition(
            for: event("PermissionRequest"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
        if case .set(let n) = t.notification {
            #expect(n.notificationType == "permission_prompt")
        } else {
            Issue.record("expected permission_prompt notification")
        }
        if case .clear = t.toolActivity {} else {
            Issue.record("expected toolActivity cleared")
        }
    }

    @Test func permissionRequestPreservesQuestionNotification() {
        let t = source.transition(
            for: event("PermissionRequest"),
            currentActivityState: .waiting,
            currentNotificationType: "question",
            currentLastTopLevelStopAt: nil
        )
        if case .leave = t.notification {} else {
            Issue.record("question notification should not be overridden")
        }
    }

    // MARK: - Blanket clear

    @Test func nonPermissionRequestClearsPendingNotification() {
        let t = source.transition(
            for: event("PreToolUse", toolName: "Bash"),
            currentActivityState: .waiting,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        if case .clear = t.notification {} else {
            Issue.record("non-PermissionRequest events should clear pending notification")
        }
    }

    @Test func unknownEventAppliesBlanketClearOnly() {
        let t = source.transition(
            for: event("FuturisticUnknownEvent"),
            currentActivityState: .working,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil)
        if case .clear = t.notification {} else {
            Issue.record("unknown events should still clear pending notification")
        }
    }
}
