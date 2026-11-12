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
        // No tmux in tests: `send` now reports a failed delivery (#1437), so
        // stand in for the pane with a sink that accepts everything.
        let handlers = makeEngineTerminalHandlers(
            appState: appState, store: store, sessionService: service, telemetryPort: nil, devRoot: root.path,
            deliverText: { _, _ in })
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

    /// `prepareTerminal` records the pasted launch only once the window is
    /// bound: with no tmux (or a failed register) nothing was launched.
    @Test @MainActor func prepareTerminalRecordsOnlyABoundWindow() throws {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1423-prep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let appState = AppState()
        let service = SessionService(store: JSONStore(directory: root.appendingPathComponent("store")), appState: appState)
        let session = Session(name: "m", kind: .manager, agentKind: .claudeCode)
        appState.sessions = [session]
        let terminal = SessionTerminal(sessionID: session.id, cwd: root.path, command: "claude --continue")

        service.terminalRegistrar = { _ in nil }  // tmux not configured
        _ = service.prepareTerminal(terminal, trackReadiness: false)
        #expect(appState.sessions.first?.launchedGateway == nil)

        service.terminalRegistrar = { _ in throw CocoaError(.featureUnsupported) }
        _ = service.prepareTerminal(terminal, trackReadiness: false)
        #expect(appState.sessions.first?.launchedGateway == nil)

        service.terminalRegistrar = { _ in
            TmuxBinding(socketPath: root.appendingPathComponent("t.sock").path, sessionName: "s", windowIndex: 1)
        }
        _ = service.prepareTerminal(terminal, trackReadiness: false)
        #expect(appState.sessions.first?.launchedGateway?.agentKind == .claudeCode)
    }

    /// The `corveil` CLI fallback is bounded like the HTTP read: a hung
    /// process is killed at the deadline instead of stalling the poller.
    @Test func cliFallbackIsKilledAtTheDeadline() async {
        let start = Date()
        let hung = await GatewayTrafficVerifier.runBounded(binary: "/bin/sleep", arguments: ["30"], timeout: 0.5)
        #expect(hung == nil)
        #expect(Date().timeIntervalSince(start) < 10)
        let ok = await GatewayTrafficVerifier.runBounded(binary: "/bin/echo", arguments: ["hi"], timeout: 5)
        #expect(ok.map { String(decoding: $0, as: UTF8.self) } == "hi\n")
        #expect(await GatewayTrafficVerifier.runBounded(binary: "/usr/bin/false", arguments: [], timeout: 5) == nil)
    }
}
