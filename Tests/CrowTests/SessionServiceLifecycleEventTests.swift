import Foundation
import Testing
import CrowCore
import CrowPersistence
@testable import Crow

/// Agent lifecycle stamping (#692, ADR 0008 follow-up 4): the hook-event
/// handler routes `SessionStart`/`SessionEnd` to
/// `SessionService.recordAgentLifecycleEvent`, which stamps wall-clock
/// timestamps on the Session in memory and in the store. Display-only —
/// telemetry's activeTimeSeconds stays the penalty-normalization clock.
@MainActor
@Suite("SessionService lifecycle events")
struct SessionServiceLifecycleEventTests {

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-lifecycle-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private static func makeFixture() -> (JSONStore, AppState, SessionService, UUID) {
        let store = tempStore()
        let appState = AppState()
        let session = Session(name: "lifecycle")
        appState.sessions = [session]
        store.mutate { $0.sessions = [session] }
        let service = SessionService(store: store, appState: appState)
        return (store, appState, service, session.id)
    }

    @Test
    func sessionStartStampsMemoryAndStoreWithoutTouchingUpdatedAt() {
        let (store, appState, service, id) = Self.makeFixture()
        let updatedAtBefore = appState.sessions[0].updatedAt
        let start = Date(timeIntervalSince1970: 1_752_000_000)

        service.recordAgentLifecycleEvent(sessionID: id, eventName: "SessionStart", at: start)

        #expect(appState.sessions[0].agentSessionStartedAt == start)
        #expect(store.data.sessions[0].agentSessionStartedAt == start)
        // The retention reaper keys off updatedAt — lifecycle stamps must not
        // extend a session's retention (same contract as setLocked).
        #expect(appState.sessions[0].updatedAt == updatedAtBefore)
        #expect(store.data.sessions[0].updatedAt == updatedAtBefore)
    }

    @Test
    func startThenEndYieldsDurationPersistedInStore() {
        let (store, appState, service, id) = Self.makeFixture()
        let start = Date(timeIntervalSince1970: 1_752_000_000)

        service.recordAgentLifecycleEvent(sessionID: id, eventName: "SessionStart", at: start)
        service.recordAgentLifecycleEvent(
            sessionID: id, eventName: "SessionEnd", at: start.addingTimeInterval(1_800))

        #expect(appState.sessions[0].wallClockDuration == 1_800)
        #expect(store.data.sessions[0].wallClockDuration == 1_800)
    }

    // SessionStart also fires on resume/clear/compact: the origin must not
    // move, but a stale end is cleared so the resumed session reads as
    // open-ended until the next SessionEnd.
    @Test
    func resumeStartKeepsOriginAndClearsEnd() {
        let (store, appState, service, id) = Self.makeFixture()
        let start = Date(timeIntervalSince1970: 1_752_000_000)

        service.recordAgentLifecycleEvent(sessionID: id, eventName: "SessionStart", at: start)
        service.recordAgentLifecycleEvent(
            sessionID: id, eventName: "SessionEnd", at: start.addingTimeInterval(1_200))
        service.recordAgentLifecycleEvent(
            sessionID: id, eventName: "SessionStart", at: start.addingTimeInterval(7_200))

        for session in [appState.sessions[0], store.data.sessions[0]] {
            #expect(session.agentSessionStartedAt == start)
            #expect(session.agentSessionEndedAt == nil)
            #expect(session.wallClockDuration == nil)
        }
    }

    @Test
    func secondEndOverwritesFirst() {
        let (_, appState, service, id) = Self.makeFixture()
        let start = Date(timeIntervalSince1970: 1_752_000_000)

        service.recordAgentLifecycleEvent(sessionID: id, eventName: "SessionStart", at: start)
        service.recordAgentLifecycleEvent(
            sessionID: id, eventName: "SessionEnd", at: start.addingTimeInterval(60))
        service.recordAgentLifecycleEvent(
            sessionID: id, eventName: "SessionEnd", at: start.addingTimeInterval(3_600))

        #expect(appState.sessions[0].wallClockDuration == 3_600)
    }

    // A session missing its end hook stays open-ended: no bogus duration.
    @Test
    func missingEndHookLeavesDurationNil() {
        let (store, appState, service, id) = Self.makeFixture()

        service.recordAgentLifecycleEvent(
            sessionID: id, eventName: "SessionStart",
            at: Date(timeIntervalSince1970: 1_752_000_000))

        #expect(appState.sessions[0].wallClockDuration == nil)
        #expect(store.data.sessions[0].wallClockDuration == nil)
    }

    @Test
    func nonLifecycleEventsAndUnknownSessionsAreNoOps() {
        let (store, appState, service, id) = Self.makeFixture()

        service.recordAgentLifecycleEvent(sessionID: id, eventName: "PostToolUse")
        service.recordAgentLifecycleEvent(sessionID: id, eventName: "Stop")
        service.recordAgentLifecycleEvent(sessionID: UUID(), eventName: "SessionStart")

        #expect(appState.sessions[0].agentSessionStartedAt == nil)
        #expect(appState.sessions[0].agentSessionEndedAt == nil)
        #expect(store.data.sessions[0].agentSessionStartedAt == nil)
    }
}
