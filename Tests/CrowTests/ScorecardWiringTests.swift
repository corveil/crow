import Foundation
import Testing
import CrowCore
import CrowPersistence
@testable import Crow

/// #710: the scorecard reads persisted snapshots through the read-only
/// `AppState.analyticsSnapshots` mirror (CrowUI cannot import CrowPersistence).
/// These tests lock in that the mirror is hydrated on load and stays in sync
/// with every snapshot write path.
@MainActor
@Suite("Scorecard snapshot mirror wiring")
struct ScorecardWiringTests {

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-scorecard-wiring-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private nonisolated static let sampleAnalytics = SessionAnalytics(
        totalCost: 2.5, inputTokens: 500, outputTokens: 900,
        activeTimeSeconds: 1_200, promptCount: 9, toolCallCount: 30
    )

    @Test
    func hydrateStatePopulatesTheMirror() {
        let store = Self.tempStore()
        let id = UUID()
        let persisted = SessionAnalyticsSnapshot(
            sessionID: id, endedAt: Date(timeIntervalSince1970: 1_752_000_000),
            status: .completed, analytics: Self.sampleAnalytics)
        store.mutate { $0.analyticsSnapshots = [id.uuidString: persisted] }

        let appState = AppState()
        let service = SessionService(store: store, appState: appState)
        service.hydrateState()

        #expect(appState.analyticsSnapshots == [id.uuidString: persisted])
    }

    @Test
    func hydrateStateWithNoSnapshotsLeavesMirrorEmpty() {
        let appState = AppState()
        let service = SessionService(store: Self.tempStore(), appState: appState)
        service.hydrateState()
        #expect(appState.analyticsSnapshots.isEmpty)
    }

    @Test
    func writeAnalyticsSnapshotUpdatesTheMirror() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "shipped")]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        #expect(appState.analyticsSnapshots[id.uuidString]
            == store.data.analyticsSnapshots?[id.uuidString])
        #expect(appState.analyticsSnapshots[id.uuidString]?.status == .completed)
    }

    @Test
    func persistStateBackfillResyncsTheMirror() {
        let store = Self.tempStore()
        let appState = AppState()
        var ended = Session(id: UUID(), name: "ended-then-quit")
        ended.status = .completed
        appState.sessions = [ended]
        appState.hookState(for: ended.id).analytics = Self.sampleAnalytics

        let service = SessionService(store: store, appState: appState)
        service.persistState()

        #expect(appState.analyticsSnapshots[ended.id.uuidString]?.analytics
            == Self.sampleAnalytics)
    }
}
