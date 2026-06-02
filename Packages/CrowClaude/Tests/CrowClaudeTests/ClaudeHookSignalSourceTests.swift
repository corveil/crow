import Foundation
import Testing
@testable import CrowClaude
@testable import CrowCore

// Exercises the state machine that used to live inline in AppDelegate's
// hook-event handler. Each case mirrors a branch of that switch so the
// behavior stays verifiably identical after extraction.

@Suite("ClaudeHookSignalSource")
struct ClaudeHookSignalSourceTests {
    private let source = ClaudeHookSignalSource()

    private func event(
        _ name: String,
        toolName: String? = nil,
        source: String? = nil,
        message: String? = nil,
        notificationType: String? = nil,
        agentType: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: UUID(),
            eventName: name,
            toolName: toolName,
            source: source,
            message: message,
            notificationType: notificationType,
            agentType: agentType,
            summary: name
        )
    }

    // MARK: - PreToolUse

    @Test func preToolUseAskUserQuestionWaits() {
        let t = source.transition(
            for: event("PreToolUse", toolName: "AskUserQuestion"),
            currentActivityState: .idle,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
        if case .set(let n) = t.notification {
            #expect(n.notificationType == "question")
        } else {
            Issue.record("expected .set notification")
        }
        if case .clear = t.toolActivity {} else {
            Issue.record("expected tool activity cleared")
        }
    }

    @Test func preToolUseOtherStartsWorking() {
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
            Issue.record("expected .set tool activity")
        }
    }

    // MARK: - PostToolUse

    @Test func postToolUseMarksActivityInactive() {
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
            Issue.record("expected .set inactive tool activity")
        }
    }

    // MARK: - Notification

    @Test func permissionPromptNotificationWaits() {
        let t = source.transition(
            for: event("Notification", message: "Approve?", notificationType: "permission_prompt"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
        if case .set(let n) = t.notification {
            #expect(n.notificationType == "permission_prompt")
        } else {
            Issue.record("expected permission_prompt set")
        }
    }

    @Test func idlePromptNotificationClearsPending() {
        let t = source.transition(
            for: event("Notification", notificationType: "idle_prompt"),
            currentActivityState: .done,
            currentNotificationType: "permission_prompt",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil) // don't change — Stop already set .done
        if case .clear = t.notification {} else {
            Issue.record("expected notification cleared")
        }
    }

    // MARK: - PermissionRequest

    @Test func permissionRequestDoesNotOverrideQuestion() {
        let t = source.transition(
            for: event("PermissionRequest"),
            currentActivityState: .waiting,
            currentNotificationType: "question",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .waiting)
        if case .leave = t.notification {} else {
            Issue.record("expected existing question notification preserved")
        }
    }

    @Test func permissionRequestSetsPermissionWhenNoQuestion() {
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
            Issue.record("expected permission_prompt set")
        }
        if case .clear = t.toolActivity {} else {
            Issue.record("expected tool activity cleared")
        }
    }

    // MARK: - Lifecycle states

    @Test func stopMarksDone() {
        let t = source.transition(
            for: event("Stop"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
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

    @Test func sessionStartFreshMarksIdle() {
        let t = source.transition(
            for: event("SessionStart", source: "startup"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .idle)
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

    // MARK: - Task/Subagent preserve waiting

    @Test func taskEventsDoNotOverrideWaiting() {
        let t = source.transition(
            for: event("TaskCreated"),
            currentActivityState: .waiting,
            currentNotificationType: "question",
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil) // preserve .waiting
    }

    @Test func taskEventsTransitionToWorkingFromOtherStates() {
        let t = source.transition(
            for: event("TaskCompleted"),
            currentActivityState: .idle,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .working)
    }

    // MARK: - Blanket notification clear

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
        #expect(t.newActivityState == .working)
    }

    @Test func unknownEventAppliesBlanketClearOnly() {
        let t = source.transition(
            for: event("PreCompact"),
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
