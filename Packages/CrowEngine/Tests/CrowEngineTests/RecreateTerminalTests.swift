import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// CROW-804 recreate-terminal wiring. `recreateTerminalSurface` drives real tmux
/// for the happy path (kill + re-register + relaunch), which the smoke suites
/// avoid — but its not-found guard and the RPC's param validation are testable
/// headlessly with a `NoopHostBridge`.
@Suite("recreate-terminal (CROW-804)")
@MainActor
struct RecreateTerminalTests {

    private func makeService() -> (SessionService, AppState, JSONStore, String) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-recreate-\(UUID().uuidString)")
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        return (service, appState, store, tmp.path)
    }

    /// An unknown terminal is a no-op that returns false — never a crash or a
    /// spurious recreate.
    @Test func returnsFalseWhenTerminalNotFound() {
        let (service, _, _, devRoot) = makeService()
        #expect(!service.recreateTerminalSurface(
            sessionID: UUID(), terminalID: UUID(), devRoot: devRoot))
    }

    /// The RPC rejects a call missing its ids rather than reaching the service.
    @Test func rpcRequiresSessionAndTerminalIDs() async throws {
        let (service, appState, store, devRoot) = makeService()
        let ctx = EngineContext(
            appState: appState, store: store, sessionService: service,
            issueTracker: nil, telemetryPort: nil, devRoot: devRoot,
            hostBridge: NoopHostBridge(), loadConfig: { nil }, applyConfig: { _ in nil })
        let router = makeEngineRouter(ctx)

        let response = await router.handle(
            request: JSONRPCRequest(id: 1, method: "recreate-terminal"))
        #expect(response.error != nil)
    }
}
