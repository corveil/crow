import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowTerminal
@testable import Crow
@testable import CrowEngine

/// Covers the #408 fix: brand-new managed terminals defer their agent launch
/// until the shell signals `.shellReady`, instead of blind-pasting into a
/// not-yet-ready shell. Pure helpers are tested directly; the readiness-handler
/// branch is exercised against a real `SessionService` with seeded state.
// Serialized: the instance tests overwrite the singleton
// `TmuxBackend.shared.onReadinessChanged` via `wireTerminalReadiness()` and then
// fire it directly. Run in parallel (Swift Testing's default) one test could
// stomp another's closure before its sentinel fires.
@Suite("Deferred managed-terminal launch (#408)", .serialized)
struct DeferredLaunchTests {

    // MARK: resolveLaunch (pure)

    @Test func resolveLaunchPastesPendingCommand() {
        let cmd = "cd /x && claude \"hi\""
        #expect(SessionService.resolveLaunch(pending: cmd) == .pastePending(cmd))
    }

    @Test func resolveLaunchFallsBackToLaunchAgentWhenNoPending() {
        #expect(SessionService.resolveLaunch(pending: nil) == .launchAgent)
        #expect(SessionService.resolveLaunch(pending: "") == .launchAgent)
    }

    // MARK: registerWithRetry (pure)

    private struct Boom: Error {}

    @Test func registerWithRetrySucceedsFirstTry() throws {
        var calls = 0
        let result = try EngineHelpers.registerWithRetry(attempts: 3) { _ in calls += 1; return 42 }
        #expect(result == 42)
        #expect(calls == 1)
    }

    @Test func registerWithRetryRecoversAfterTransientFailures() throws {
        var calls = 0
        let result = try EngineHelpers.registerWithRetry(attempts: 3) { attempt -> Int in
            calls += 1
            if attempt < 2 { throw Boom() }
            return 7
        }
        #expect(result == 7)
        #expect(calls == 3)
    }

    @Test func registerWithRetryThrowsAfterExhaustion() {
        var calls = 0
        #expect(throws: Boom.self) {
            try EngineHelpers.registerWithRetry(attempts: 3) { _ -> Int in calls += 1; throw Boom() }
        }
        #expect(calls == 3)
    }

    // MARK: deferred paste on .shellReady (instance)

    /// When the sentinel fires `.shellReady` for a terminal staged exactly as
    /// the `new-terminal` RPC stages a brand-new managed launch, the readiness
    /// handler pastes the pending command and advances to `.agentLaunched`,
    /// consuming BOTH the pending command and the autoLaunch membership so
    /// `launchAgent` can never also fire (no double launch).
    @MainActor
    @Test func shellReadyPastesPendingCommandAndConsumesState() {
        let appState = AppState()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-defer-\(UUID().uuidString)")
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState)

        let sessionID = UUID()
        let terminalID = UUID()
        let command = "cd \(tmp.path) && claude \"hi\""
        appState.sessions = [Session(id: sessionID, name: "feat", kind: .work)]
        appState.terminals[sessionID] = [SessionTerminal(
            id: terminalID, sessionID: sessionID, name: "Claude Code",
            cwd: tmp.path, command: command, isManaged: true, tmuxBinding: nil
        )]
        // Stage the deferred launch exactly like the new-terminal RPC.
        appState.terminalReadiness[terminalID] = .uninitialized
        appState.pendingLaunchCommands[terminalID] = command
        appState.autoLaunchTerminals.insert(terminalID)

        service.wireTerminalReadiness()
        // Fire the sentinel's `.shellReady` exactly as the backend would.
        TmuxBackend.shared.onReadinessChanged?(terminalID, .shellReady)

        #expect(appState.pendingLaunchCommands[terminalID] == nil)
        #expect(!appState.autoLaunchTerminals.contains(terminalID))
        #expect(appState.terminalReadiness[terminalID] == .agentLaunched)
    }

    /// A `.timedOut` before `.shellReady` must NOT paste or consume the pending
    /// command — the launch is recoverable via Retry / app-foreground re-arm.
    @MainActor
    @Test func timedOutDoesNotConsumePendingLaunch() {
        let appState = AppState()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-defer-timeout-\(UUID().uuidString)")
        let service = SessionService(store: JSONStore(directory: tmp), appState: appState)

        let sessionID = UUID()
        let terminalID = UUID()
        let command = "cd \(tmp.path) && claude \"hi\""
        appState.sessions = [Session(id: sessionID, name: "feat", kind: .work)]
        appState.terminals[sessionID] = [SessionTerminal(
            id: terminalID, sessionID: sessionID, name: "Claude Code",
            cwd: tmp.path, command: command, isManaged: true, tmuxBinding: nil
        )]
        appState.terminalReadiness[terminalID] = .uninitialized
        appState.pendingLaunchCommands[terminalID] = command
        appState.autoLaunchTerminals.insert(terminalID)

        service.wireTerminalReadiness()
        TmuxBackend.shared.onReadinessChanged?(terminalID, .timedOut)

        #expect(appState.terminalReadiness[terminalID] == .timedOut)
        // Pending launch survives so a later `.shellReady` (Retry) still pastes.
        #expect(appState.pendingLaunchCommands[terminalID] == command)
        #expect(appState.autoLaunchTerminals.contains(terminalID))
    }
}
