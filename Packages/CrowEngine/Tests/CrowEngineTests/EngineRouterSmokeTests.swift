import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// Proves the engine's RPC router can be constructed and driven headlessly with
/// a `NoopHostBridge` — no AppKit, no desktop app. This is the invariant that
/// lets the `crowd` daemon host `makeEngineRouter` in a later milestone
/// (CROW-581 headless-engine migration, A7).
@Suite("makeEngineRouter smoke")
@MainActor
struct EngineRouterSmokeTests {
    @Test("router builds with NoopHostBridge and dispatches list-sessions")
    func listSessionsDispatch() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-engine-smoke-\(UUID().uuidString)")
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())

        let ctx = EngineContext(
            appState: appState,
            store: store,
            sessionService: service,
            issueTracker: nil,
            telemetryPort: nil,
            devRoot: tmp.path,
            hostBridge: NoopHostBridge(),
            loadConfig: { nil },
            applyConfig: { _ in nil }
        )
        let router = makeEngineRouter(ctx)

        let response = await router.handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
        #expect(response.error == nil)
        #expect(response.result != nil)
    }
}
