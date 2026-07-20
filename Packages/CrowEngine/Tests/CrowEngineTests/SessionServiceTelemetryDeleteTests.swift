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

    /// The purge must sit AFTER the disk-cleanup guard: a retryable failure leaves
    /// the session (and the user's ability to retry) intact, so its metrics have to
    /// survive too. Forces the failure by making the clone's parent read-only, so
    /// `removeItem` fails with EACCES.
    @Test @MainActor
    func failedDiskCleanupKeepsTelemetryRows() async {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-tel-del-locked-\(UUID().uuidString)")
        let clone = parent.appendingPathComponent("clone")
        try? fm.createDirectory(at: clone, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? fm.removeItem(at: parent)
        }

        // A review session: repoPath == worktreePath == the clone, which is the
        // branch that reports a fatal error when the directory can't be removed.
        let session = Session(name: "__TEST__TelemetryDeleteFailed", kind: .review)
        let appState = AppState()
        appState.sessions = [session]
        appState.worktrees[session.id] = [SessionWorktree(
            sessionID: session.id, repoName: "repo", repoPath: clone.path,
            worktreePath: clone.path, branch: "feature/pr")]
        let recorder = DeleteRecorder()

        await service(appState: appState, recorder: recorder).deleteSession(id: session.id)

        // Cleanup failed → session preserved for retry, telemetry preserved with it.
        #expect(appState.sessions.count == 1)
        #expect(appState.sessionDeletionError[session.id] != nil)
        #expect(recorder.ids.isEmpty)
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
