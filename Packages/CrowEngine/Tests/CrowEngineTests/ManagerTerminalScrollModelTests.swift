import Foundation
import Testing
import CrowClaude
import CrowCore
import CrowPersistence
@testable import CrowEngine

/// CROW-1404: an extra Manager launched with a seed prompt registered its tmux
/// window from a command-less copy of its terminal row. For a Manager terminal
/// `isAgentSurface` is `command != nil`, so the window was classified as a
/// plain shell and never got `alternate-screen on` (ADR-0013). Claude Code then
/// painted into the main buffer and its earlier history was unreachable.
///
/// These tests record what each Manager launch path asks the terminal backend
/// for. `TmuxBackend.registerTerminal` turns `agentSurface: true` into the
/// window option; `TmuxBackendTests` covers that half against a real server.
@MainActor
@Suite("Manager terminal scroll model (CROW-1404)", .serialized)
struct ManagerTerminalScrollModelTests {
    private final class SpyHookConfigWriter: HookConfigWriter, @unchecked Sendable {
        func writeHookConfig(worktreePath: String, sessionID: UUID, crowPath: String) throws {}
        func removeHookConfig(worktreePath: String) {}
    }

    private struct NoopStateSignalSource: StateSignalSource {
        func transition(
            for event: AgentHookEvent,
            currentActivityState: AgentActivityState,
            currentNotificationType: String?,
            currentLastTopLevelStopAt: Date?
        ) -> AgentStateTransition { AgentStateTransition() }
    }

    /// A Manager agent with no trust seed, no global MCP bridge and no gateway
    /// env, so a launch only writes inside the test's own temp directory.
    private struct StubAgent: CodingAgent {
        let kind: AgentKind
        var displayName: String { kind.rawValue }
        var iconSystemName: String { "sparkles" }
        var supportsRemoteControl: Bool { false }
        var launchCommandToken: String { kind.rawValue }
        let hookConfigWriter: any HookConfigWriter = SpyHookConfigWriter()
        let stateSignalSource: any StateSignalSource = NoopStateSignalSource()
        func findBinary() -> String? { "/usr/bin/true" }
        func autoLaunchCommand(
            session: Session,
            worktreePath: String,
            remoteControlEnabled: Bool,
            autoPermissionMode: Bool,
            telemetryPort: UInt16?
        ) -> String? { nil }
        func generatePrompt(
            session: Session,
            worktrees: [SessionWorktree],
            ticketURL: String?,
            provider: Provider?,
            codeProvider: Provider?
        ) async -> String { "" }
        func launchCommand(sessionID: UUID, worktreePath: String, prompt: String) async throws -> String {
            "\(kind.rawValue)\n"
        }
        func managerLaunchCommand(
            sessionName: String,
            remoteControlEnabled: Bool,
            autoPermissionMode: Bool,
            telemetryPort: UInt16?,
            conversationID: String?
        ) -> String { kind.rawValue }
    }

    @MainActor
    private final class Recorder {
        var registrations: [TerminalRegistration] = []
    }

    private static let managerKind = AgentKind(rawValue: "crow-1404-stub-manager")
    private static let handoffKind = AgentKind(rawValue: "crow-1404-stub-handoff")

    private struct Fixture {
        let service: SessionService
        let appState: AppState
        let recorder: Recorder
        let root: URL
        let cwd: String
    }

    private func makeFixture() throws -> Fixture {
        // Claude first keeps it the process-wide default for the other suites
        // that share this registry; the stubs only add kinds.
        AgentRegistry.shared.register(ClaudeCodeAgent())
        AgentRegistry.shared.register(StubAgent(kind: Self.managerKind))
        AgentRegistry.shared.register(StubAgent(kind: Self.handoffKind))

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1404-\(UUID().uuidString)")
        let cwd = root.appendingPathComponent("manager")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

        let appState = AppState()
        let service = SessionService(
            store: JSONStore(directory: root.appendingPathComponent("store")), appState: appState)
        let recorder = Recorder()
        service.terminalRegistrar = { registration in
            recorder.registrations.append(registration)
            return TmuxBinding(
                socketPath: root.appendingPathComponent("tmux.sock").path,
                sessionName: "crow-cockpit",
                windowIndex: recorder.registrations.count)
        }
        return Fixture(
            service: service, appState: appState, recorder: recorder, root: root, cwd: cwd.path)
    }

    private func cleanUp(_ fixture: Fixture, sessionID: UUID?) {
        try? FileManager.default.removeItem(at: fixture.root)
        if let sessionID {
            try? FileManager.default.removeItem(atPath: TodoRPC.explorePromptPath(sessionID: sessionID))
            try? FileManager.default.removeItem(atPath: TodoRPC.handoffPromptPath(sessionID: sessionID))
        }
    }

    /// The bug: Scratch Explore / ticket Managers, and every workspace-tagged
    /// extra Manager, are seeded. The window must still be an agent surface.
    @Test func seededExtraManagerRegistersAnAgentSurfaceWindow() throws {
        let fixture = try makeFixture()
        var sessionID: UUID?
        defer { cleanUp(fixture, sessionID: sessionID) }

        let id = fixture.service.createManagerSession(
            name: "Explore CROW-1404", cwd: fixture.cwd, agentKind: Self.managerKind,
            initialPrompt: "Explore why the Manager lost its scrollback.")
        sessionID = id

        let registration = try #require(fixture.recorder.registrations.only)
        #expect(registration.agentSurface, "a seeded Manager window needs alternate-screen")
        // The launch is deferred to `.shellReady`, so nothing is pasted now.
        #expect(registration.command == nil)
        #expect(registration.trackReadiness)

        // The persisted row still carries the bare Manager command (recreate /
        // hydrate relaunch from it) and agrees with how the window was born.
        let terminal = try #require(fixture.appState.terminals(for: id).only)
        #expect(terminal.id == registration.id)
        #expect(terminal.command == Self.managerKind.rawValue)
        #expect(terminal.tmuxBinding != nil)
        let session = try #require(fixture.appState.sessions.first(where: { $0.id == id }))
        #expect(terminal.isAgentSurface(session: session))
        let stored = try #require(fixture.service.store.data.terminals.first(where: { $0.id == terminal.id }))
        #expect(stored.command == terminal.command)

        // The seed itself waits in `pendingLaunchCommands`, pointing at the brief.
        let pending = try #require(fixture.appState.pendingLaunchCommands[terminal.id])
        #expect(pending.contains(TodoRPC.explorePromptPath(sessionID: id)))
    }

    /// Control: an unseeded extra Manager pastes its command at once and was
    /// already classified correctly before CROW-1404.
    @Test func unseededExtraManagerPastesItsCommandIntoAnAgentSurfaceWindow() throws {
        let fixture = try makeFixture()
        var sessionID: UUID?
        defer { cleanUp(fixture, sessionID: sessionID) }

        let id = fixture.service.createManagerSession(
            name: "Plain Manager", cwd: fixture.cwd, agentKind: Self.managerKind)
        sessionID = id

        let registration = try #require(fixture.recorder.registrations.only)
        #expect(registration.agentSurface)
        #expect(registration.command == Self.managerKind.rawValue)
        #expect(!registration.trackReadiness)
        let terminal = try #require(fixture.appState.terminals(for: id).only)
        #expect(fixture.appState.pendingLaunchCommands[terminal.id] == nil)
    }

    /// Extra-Manager handoff recreates the agent pane through the same seeded
    /// path, with the resume brief as the seed.
    @Test func seededExtraManagerHandoffRegistersAnAgentSurfaceWindow() async throws {
        let fixture = try makeFixture()
        var sessionID: UUID?
        defer { cleanUp(fixture, sessionID: sessionID) }

        let id = fixture.service.createManagerSession(
            name: "Handoff Manager", cwd: fixture.cwd, agentKind: Self.managerKind)
        sessionID = id
        let original = try #require(fixture.appState.terminals(for: id).only)

        let newID = try await fixture.service.handoffAgent(sessionID: id, to: Self.handoffKind)

        #expect(fixture.recorder.registrations.count == 2)
        let registration = try #require(fixture.recorder.registrations.last)
        #expect(registration.id == newID)
        #expect(registration.agentKind == Self.handoffKind)
        #expect(registration.agentSurface, "a handed-off Manager window needs alternate-screen")
        #expect(registration.command == nil)
        #expect(registration.trackReadiness)

        let terminal = try #require(fixture.appState.terminals(for: id).only)
        #expect(terminal.id == newID)
        #expect(terminal.id != original.id)
        #expect(terminal.command == Self.handoffKind.rawValue)
        let pending = try #require(fixture.appState.pendingLaunchCommands[newID])
        #expect(pending.contains(TodoRPC.handoffPromptPath(sessionID: id)))
    }
}

private extension Array {
    /// The sole element, or nil when there are zero or several.
    var only: Element? { count == 1 ? first : nil }
}
