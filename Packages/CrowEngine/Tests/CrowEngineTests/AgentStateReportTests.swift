import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// `agent_state` / `last_prompt_at` / `agent_terminal_id` on `get-session`,
/// driven through the real router and `hook-event` handler (CROW-1475).
@Suite("get-session agent readiness")
@MainActor
struct AgentStateReportTests {

    private func makeRouter(_ appState: AppState) -> CommandRouter {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-agent-state-\(UUID().uuidString)")
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        return makeEngineRouter(EngineContext(
            appState: appState,
            store: store,
            sessionService: service,
            issueTracker: nil,
            telemetryPort: nil,
            devRoot: tmp.path,
            hostBridge: NoopHostBridge(),
            loadConfig: { nil },
            applyConfig: { _ in nil }
        ))
    }

    private func getSession(_ router: CommandRouter, _ id: UUID) async throws -> [String: JSONValue] {
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "get-session", params: ["session_id": .string(id.uuidString)]))
        return try #require(response.result)
    }

    private func hook(_ router: CommandRouter, _ id: UUID, _ event: String) async {
        _ = await router.handle(request: JSONRPCRequest(
            id: 2, method: "hook-event", params: [
                "session_id": .string(id.uuidString),
                "event_name": .string(event),
                "payload": .object([:]),
            ]))
    }

    @Test("a session with no agent terminal reports null fields")
    func noAgentTerminal() async throws {
        let appState = AppState()
        let session = Session(name: "bare")
        appState.sessions.append(session)
        // A Shell tab is not an agent terminal.
        appState.terminals[session.id] = [SessionTerminal(sessionID: session.id, cwd: "/tmp")]

        let result = try await getSession(makeRouter(appState), session.id)
        #expect(result["agent_state"] == .null)
        #expect(result["agent_terminal_id"] == .null)
        #expect(result["last_prompt_at"] == .null)
    }

    @Test("a launch reads starting until the first hook, and a prompt stamps last_prompt_at")
    func launchThenHooks() async throws {
        let appState = AppState()
        let session = Session(name: "work")
        appState.sessions.append(session)
        let terminal = SessionTerminal(sessionID: session.id, name: "Claude Code", cwd: "/tmp", isManaged: true)
        appState.terminals[session.id] = [terminal]
        appState.terminalReadiness[terminal.id] = .agentLaunched
        appState.noteAgentLaunch(sessionID: session.id)
        let router = makeRouter(appState)

        var result = try await getSession(router, session.id)
        #expect(result["agent_state"] == .string("starting"))
        #expect(result["agent_terminal_id"] == .string(terminal.id.uuidString))

        await hook(router, session.id, "UserPromptSubmit")
        let state = appState.hookState(for: session.id)
        #expect(!state.agentLaunchPending)
        // Independent of which signal source is registered in this process.
        state.activityState = .working

        result = try await getSession(router, session.id)
        #expect(result["agent_state"] == .string("working"))
        let stamp = try #require(result["last_prompt_at"]?.stringValue)
        // Milliseconds, so `--wait-ack` sees two prompts in one second differ.
        #expect(stamp.contains("."))
    }
}
