import Foundation
import Testing
import CrowCore
import CrowEngine
import CrowPersistence
import CrowProvider
@testable import CrowDaemon

/// CROW-782 — the terminal-independent automation providers must come up armed
/// whenever `crowd` runs. They used to be wired inside the daemon's
/// `if let sessionService` (tmux-present) branch, so a daemon started without
/// tmux on its PATH left every provider at its `{ false }` default and silently
/// disabled auto-merge, auto-respond, auto-rebase and crow:auto at once.
@Suite("Daemon tracker automation wiring (tmux-independent)")
struct TrackerAutomationWiringTests {

    /// A temp devRoot with `.claude/config.json` written from `config`.
    private func makeDevRoot(_ config: AppConfig) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-test-devroot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try ConfigStore.saveConfig(config, devRoot: root.path)
        return root.path
    }

    @MainActor
    private func makeTracker(appState: AppState) -> IssueTracker {
        IssueTracker(appState: appState, providerManager: ProviderManager(), store: .temporary())
    }

    @Test @MainActor func providersReflectEnabledConfigWithoutASessionService() throws {
        var config = AppConfig()
        config.autoMergeWatcherEnabled = true
        config.autoCreateWatcherEnabled = true
        config.autoRespond.respondToChangesRequested = true
        config.autoRespond.autoRebaseAndResolveConflicts = true
        let devRoot = try makeDevRoot(config)
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let appState = AppState()
        let tracker = makeTracker(appState: appState)
        // No SessionService, no cockpit — exactly the no-tmux daemon.
        CrowDaemon.wireTrackerAutomations(tracker: tracker, appState: appState, devRoot: devRoot)

        #expect(tracker.autoMergeWatcherEnabledProvider())
        #expect(tracker.autoCreateWatcherEnabledProvider())
        #expect(tracker.respondToChangesRequestedProvider())
        #expect(tracker.autoRebaseAndResolveConflictsProvider())
    }

    @Test @MainActor func providersReflectDisabledConfig() throws {
        var config = AppConfig()
        config.autoMergeWatcherEnabled = false
        config.autoCreateWatcherEnabled = false
        // `respondToChangesRequested` ships on by default, so opt out explicitly.
        config.autoRespond.respondToChangesRequested = false
        config.autoRespond.autoRebaseAndResolveConflicts = false
        let devRoot = try makeDevRoot(config)
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let appState = AppState()
        let tracker = makeTracker(appState: appState)
        CrowDaemon.wireTrackerAutomations(tracker: tracker, appState: appState, devRoot: devRoot)

        #expect(!tracker.autoMergeWatcherEnabledProvider())
        #expect(!tracker.autoCreateWatcherEnabledProvider())
        #expect(!tracker.respondToChangesRequestedProvider())
        #expect(!tracker.autoRebaseAndResolveConflictsProvider())
    }

    @Test @MainActor func providersRereadConfigOnEveryCall() throws {
        var config = AppConfig()
        config.autoMergeWatcherEnabled = false
        let devRoot = try makeDevRoot(config)
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let appState = AppState()
        let tracker = makeTracker(appState: appState)
        CrowDaemon.wireTrackerAutomations(tracker: tracker, appState: appState, devRoot: devRoot)
        #expect(!tracker.autoMergeWatcherEnabledProvider())

        // Toggling the setting takes effect on the next poll — no daemon restart.
        config.autoMergeWatcherEnabled = true
        try ConfigStore.saveConfig(config, devRoot: devRoot)
        #expect(tracker.autoMergeWatcherEnabledProvider())
    }
}
