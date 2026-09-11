import Foundation
import Testing
@testable import CrowCore

// MARK: - HookEvent Tests

@Test func hookEventInitDefaults() {
    let sessionID = UUID()
    let before = Date()
    let event = HookEvent(sessionID: sessionID, eventName: "Stop", summary: "Session stopped")
    let after = Date()
    #expect(event.sessionID == sessionID)
    #expect(event.eventName == "Stop")
    #expect(event.summary == "Session stopped")
    #expect(event.timestamp >= before && event.timestamp <= after)
}

@Test func hookEventCustomIDAndTimestamp() {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_000_000)
    let event = HookEvent(id: id, sessionID: UUID(), eventName: "PreToolUse", summary: "Using Bash", timestamp: date)
    #expect(event.id == id)
    #expect(event.timestamp == date)
}

@Test func hookEventStoresAllFields() {
    let sessionID = UUID()
    let event = HookEvent(sessionID: sessionID, eventName: "Notification", summary: "Task complete")
    #expect(event.sessionID == sessionID)
    #expect(event.eventName == "Notification")
    #expect(event.summary == "Task complete")
}

@Test @MainActor func resetForAgentRelaunchDropsLiveSignalsAndKeepsAnalytics() {
    let sessionID = UUID()
    let state = SessionHookState()
    state.activityState = .working
    state.pendingNotification = HookNotification(message: "n", notificationType: "permission")
    state.hookEvents = [
        HookEvent(sessionID: sessionID, eventName: "SessionStart", summary: "up"),
        HookEvent(sessionID: sessionID, eventName: "Stop", summary: "done"),
    ]
    state.lastTopLevelStopAt = Date()
    state.compactionCount = 3
    state.resetForAgentRelaunch()
    #expect(state.hookEvents.isEmpty)
    #expect(state.activityState == .idle)
    #expect(state.pendingNotification == nil)
    #expect(state.lastToolActivity == nil)
    #expect(state.lastTopLevelStopAt == nil)
    #expect(state.compactionCount == 3)
}

@Test @MainActor func resetHookStateForAgentRelaunchIsANoOpWhenEmpty() {
    let app = AppState()
    let sid = UUID()
    app.resetHookStateForAgentRelaunch(sessionID: sid)
    #expect(app.existingHookState(for: sid) == nil)

    let state = app.hookState(for: sid)
    state.activityState = .waiting
    state.hookEvents = [HookEvent(sessionID: sid, eventName: "SessionStart", summary: "up")]
    app.resetHookStateForAgentRelaunch(sessionID: sid)
    #expect(state.activityState == .idle)
    #expect(state.hookEvents.isEmpty)
}
