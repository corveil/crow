import Foundation
import Testing
import CrowClaude
import CrowCore
import CrowIPC
import CrowPersistence
@testable import CrowEngine

/// CROW-1423 review: `crow send … "claude …"` (the documented pane-recovery
/// path) is a launch, so it updates `Session.launchedGateway`; a reply typed
/// into a running agent is not.
@Suite struct SendRecordsLaunchTests {
    @MainActor
    private func fixture() throws -> (handler: CommandRouter.Handler, appState: AppState, session: Session,
                                      terminal: SessionTerminal, root: URL) {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1423-send-\(UUID().uuidString)")
        let cwd = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let appState = AppState()
        let store = JSONStore(directory: root.appendingPathComponent("store"))
        let service = SessionService(store: store, appState: appState)
        let session = Session(name: "w", kind: .work, agentKind: .claudeCode)
        let terminal = SessionTerminal(sessionID: session.id, cwd: cwd.path, command: "claude", isManaged: true)
        appState.sessions = [session]
        appState.terminals[session.id] = [terminal]
        let handlers = makeEngineTerminalHandlers(
            appState: appState, store: store, sessionService: service, telemetryPort: nil, devRoot: root.path)
        return (try #require(handlers["send"]), appState, session, terminal, root)
    }

    private func params(_ session: Session, _ terminal: SessionTerminal, _ text: String) -> [String: JSONValue] {
        ["session_id": .string(session.id.uuidString), "terminal_id": .string(terminal.id.uuidString),
         "text": .string(text)]
    }

    @Test @MainActor func sendingAnAgentLaunchRecordsIt() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.handler(params(f.session, f.terminal,
            "export ANTHROPIC_BASE_URL='https://gw.example' && claude --continue\n"))
        let record = try #require(f.appState.sessions.first?.launchedGateway)
        #expect(record.via == .launchLine)
        #expect(record.baseURL == "https://gw.example")
        #expect(record.agentKind == .claudeCode)
    }

    @Test @MainActor func sendingAReplyIsNotALaunch() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.handler(params(f.session, f.terminal, "yes\n"))
        #expect(f.appState.sessions.first?.launchedGateway == nil)
    }
}
