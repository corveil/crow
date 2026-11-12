import Foundation
import Testing
import CrowCore
import CrowIPC
import CrowPersistence
@testable import CrowEngine

/// #1437: the `send` RPC reports a failed delivery instead of `sent: true`,
/// and `raw: true` (the web Chat view) sends the text exactly as typed.
@Suite struct SendDeliveryTests {
    @MainActor
    final class Pane {
        var received: [String] = []
        var failure: (any Error)?
    }

    struct Fixture {
        let handler: CommandRouter.Handler
        let session: Session
        let terminal: SessionTerminal
        let pane: Pane
        let root: URL
    }

    @MainActor
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1437-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let appState = AppState()
        let store = JSONStore(directory: root.appendingPathComponent("store"))
        let service = SessionService(store: store, appState: appState)
        // A plain (unmanaged) terminal: no agent-launch preparation runs, so
        // the handler hands the text straight to `deliverText`.
        let session = Session(name: "w", kind: .work, agentKind: .claudeCode)
        let terminal = SessionTerminal(sessionID: session.id, cwd: root.path, command: nil, isManaged: false)
        appState.sessions = [session]
        appState.terminals[session.id] = [terminal]
        let pane = Pane()
        let handlers = makeEngineTerminalHandlers(
            appState: appState, store: store, sessionService: service, telemetryPort: nil, devRoot: root.path,
            deliverText: { _, text in
                if let failure = pane.failure { throw failure }
                pane.received.append(text)
            })
        return Fixture(handler: try #require(handlers["send"]), session: session, terminal: terminal,
                       pane: pane, root: root)
    }

    private func params(_ f: Fixture, _ text: String, raw: Bool? = nil,
                        terminal: UUID? = nil) -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "session_id": .string(f.session.id.uuidString),
            "terminal_id": .string((terminal ?? f.terminal.id).uuidString),
            "text": .string(text),
        ]
        if let raw { p["raw"] = .bool(raw) }
        return p
    }

    /// `crow send "yes\n"` keeps its documented meaning: a literal `\n`
    /// becomes a real newline (Enter), `\t` a tab.
    @Test @MainActor func cliSendRewritesLiteralEscapes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let result = try await f.handler(params(f, #"a\tb\n"#))
        #expect(result == ["sent": .bool(true)])
        #expect(f.pane.received == ["a\tb\n"])
    }

    /// The Chat view sends `raw: true`: pasted code keeps its escapes.
    @Test @MainActor func rawSendLeavesLiteralEscapesAlone() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let typed = #"print("a\nb\tc")"# + "\nsecond line\n"
        _ = try await f.handler(params(f, typed, raw: true))
        #expect(f.pane.received == [typed])
    }

    @Test @MainActor func rawFalseBehavesLikeTheCLI() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.handler(params(f, #"x\n"#, raw: false))
        #expect(f.pane.received == ["x\n"])
    }

    /// A tmux failure used to be logged and answered with `sent: true`, so
    /// the Chat view cleared the composer and the text was lost.
    @Test @MainActor func failedDeliveryIsAnError() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.pane.failure = CocoaError(.fileWriteUnknown)
        await #expect(throws: RPCError.self) {
            _ = try await f.handler(params(f, "hello\n", raw: true))
        }
    }

    @Test @MainActor func unknownTerminalIsAnError() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: RPCError.self) {
            _ = try await f.handler(params(f, "hello\n", terminal: UUID()))
        }
        #expect(f.pane.received.isEmpty)
    }
}
