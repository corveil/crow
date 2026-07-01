import Foundation
import Testing
@testable import CrowOpenCode
@testable import CrowCore

@Suite("OpenCodeSignalSource")
struct OpenCodeSignalSourceTests {
    private let source = OpenCodeSignalSource()

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

    @Test func sessionStartFreshIdle() {
        let t = source.transition(
            for: event("SessionStart", source: "startup"),
            currentActivityState: .done,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: Date()
        )
        #expect(t.newActivityState == .idle)
    }

    @Test func preToolUseSetsWorking() {
        let t = source.transition(
            for: event("PreToolUse", toolName: "bash"),
            currentActivityState: .idle,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .working)
        if case .set(let activity) = t.toolActivity {
            #expect(activity.toolName == "bash")
            #expect(activity.isActive == true)
        } else {
            Issue.record("expected tool activity set active")
        }
    }

    @Test func postToolUseMarksInactive() {
        let t = source.transition(
            for: event("PostToolUse", toolName: "bash"),
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

    @Test func sessionIdleMappedToStopMarksDone() {
        // OpenCode's `session.idle` → canonical `Stop` in the plugin; the
        // signal source drives `.done` + records the top-level stop.
        let t = source.transition(
            for: event("Stop"),
            currentActivityState: .working,
            currentNotificationType: nil,
            currentLastTopLevelStopAt: nil
        )
        #expect(t.newActivityState == .done)
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
