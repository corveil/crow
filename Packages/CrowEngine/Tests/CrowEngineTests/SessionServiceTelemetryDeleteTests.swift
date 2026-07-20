import Foundation
import Testing
import CrowCore
import CrowPersistence
@testable import CrowEngine

/// `deleteSession` is the single choke point for dropping a session's raw
/// telemetry rows (#772) — the daemon's `delete-session` handler, the
/// engine-router fallback, and the auto-cleanup reaper all funnel through it, so
/// injecting the cleanup here is what keeps telemetry.db from accumulating rows
/// for sessions that no longer exist.
@Suite("SessionService telemetry cleanup on delete")
struct SessionServiceTelemetryDeleteTests {

    /// Collects the ids the provider was called with. A class (not an actor) so
    /// the MainActor-isolated assertions read it without hopping; the provider
    /// closure only ever runs from `deleteSession`, itself `@MainActor`.
    @MainActor
    private final class DeleteRecorder {
        var ids: [UUID] = []
    }

    private static func tempStore() -> JSONStore {
        JSONStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-tel-del-\(UUID().uuidString)"))
    }

    @MainActor
    private func service(appState: AppState, recorder: DeleteRecorder) -> SessionService {
        SessionService(
            store: Self.tempStore(), appState: appState,
            telemetryDeleteProvider: { id in
                await MainActor.run { recorder.ids.append(id) }
            })
    }

    @Test @MainActor
    func deletingASessionDropsItsTelemetryRows() async {
        // No worktrees → `performDiskCleanup` has nothing to do and succeeds, so
        // the delete reaches its teardown tail.
        let session = Session(name: "__TEST__TelemetryDelete", kind: .work)
        let appState = AppState()
        appState.sessions = [session]
        let recorder = DeleteRecorder()

        await service(appState: appState, recorder: recorder).deleteSession(id: session.id)

        #expect(appState.sessions.isEmpty)
        #expect(recorder.ids == [session.id])
    }

    /// The primary Manager can't be deleted, so nothing may be purged for it —
    /// its telemetry backs the scorecard's weekly usage rollups.
    @Test @MainActor
    func managerSessionIsNeverPurged() async {
        let appState = AppState()
        appState.sessions = [Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)]
        let recorder = DeleteRecorder()

        await service(appState: appState, recorder: recorder)
            .deleteSession(id: AppState.managerSessionID)

        #expect(appState.sessions.count == 1)
        #expect(recorder.ids.isEmpty)
    }
}
