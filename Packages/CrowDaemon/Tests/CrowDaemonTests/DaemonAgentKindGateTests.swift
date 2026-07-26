import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// #834: the daemon's `new-session` surface must run a requested `agent_kind`
/// through the same shared registry gate the app's surfaces use — closing the
/// asymmetry where only the web `create-manager` (CROW-593) validated. An
/// unregistered kind falls back to the configured default (so the session isn't
/// persisted with a kind that would leave it unlaunchable); a registered kind
/// passes through.
@Suite("daemon new-session agent_kind gate")
struct DaemonAgentKindGateTests {

    @MainActor
    private func makeRouter(appState: AppState, store: JSONStore) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: store, git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil)
    }

    @Test @MainActor func gatesAgentKindAgainstRegistry() async {
        AgentRegistry.shared.register(ClaudeCodeAgent())

        let appState = AppState()
        // Configured default is a kind NOT registered here (only Claude is), so
        // the fallback is distinguishable from the registered passthrough — and
        // it mirrors the web gate: only the *requested* kind is validated, the
        // configured default is trusted as-is (CROW-593).
        appState.defaultAgentKind = .codex
        let store = JSONStore.temporary()
        let router = makeRouter(appState: appState, store: store)

        func createSession(agentKind: String) async -> JSONRPCResponse {
            await router.handle(request: JSONRPCRequest(id: 1, method: "new-session", params: [
                "name": .string("s"), "agent_kind": .string(agentKind),
            ]))
        }

        // Registered kind (non-default) → honored, proving the gate isn't just
        // always returning the default.
        let claude = await createSession(agentKind: AgentKind.claudeCode.rawValue)
        #expect(claude.error == nil)
        #expect(claude.result?["agent_kind"]?.stringValue == AgentKind.claudeCode.rawValue)

        // Unregistered kind → falls back to the configured default.
        let unknown = await createSession(agentKind: "crow-834-unregistered-daemon")
        #expect(unknown.error == nil)
        #expect(unknown.result?["agent_kind"]?.stringValue == AgentKind.codex.rawValue)
    }
}
