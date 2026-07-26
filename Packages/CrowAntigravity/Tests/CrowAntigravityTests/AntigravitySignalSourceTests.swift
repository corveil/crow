import Foundation
import Testing
@testable import CrowAntigravity
@testable import CrowCore

@Suite("AntigravitySignalSource")
struct AntigravitySignalSourceTests {
    private let source = AntigravitySignalSource()

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

    // MARK: - Invocation boundaries

    @Test func preInvocationSetsWorkingAndClearsStop() {
        let t = source.transition(
            for: event("PreInvocation"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == .working)
        if case .clear = t.lastTopLevelStopAt {} else {
            Issue.record("PreInvocation should clear lastTopLevelStopAt (new turn)")
        }
    }

    @Test func postInvocationIsObservationalOnly() {
        // PostInvocation must NOT flip to done — Stop (fullyIdle) is the
        // authoritative done signal; a multi-step turn emits several invocations.
        let t = source.transition(
            for: event("PostInvocation"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == nil)
    }

    // MARK: - Tool activity

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

    @Test func postToolUseIsWorkingHeartbeatWithoutBogusToolName() {
        // Antigravity's PostToolUse stdin has no tool name, so we must NOT surface
        // a bogus "unknown" tool — just keep the working heartbeat.
        let t = source.transition(
            for: event("PostToolUse"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .working)
        if case .leave = t.toolActivity {} else {
            Issue.record("PostToolUse should not set a (bogus) tool activity")
        }
    }

    @Test func postToolUseAfterStopDoesNotReElevate() {
        // A stray PostToolUse after Stop must not flip back to working.
        let t = source.transition(
            for: event("PostToolUse"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == nil)
    }

    // MARK: - Stop (fullyIdle → done)

    @Test func stopMarksDoneAndSetsStopAt() {
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

    // MARK: - PermissionRequest (defensive parity — not emitted by the writer)

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
            for: event("SomeFutureEvent"),
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
