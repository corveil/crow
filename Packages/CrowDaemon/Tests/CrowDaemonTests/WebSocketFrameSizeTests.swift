import CrowIPC
import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWebSocket
import HummingbirdWSClient
import HummingbirdWSTesting
import NIOCore
import NIOWebSocket
import Testing

@testable import CrowDaemon

/// CROW-956. `crowd` used to build its upgrade channel with no WebSocket
/// configuration, leaving NIO's frame decoder at its default `maxFrameSize` of
/// 16 KiB. A browser sends one unfragmented frame per `ws.send()` — a fat
/// `set-config` (`app.js`) and a paste into xterm.js alike — so anything larger
/// was answered with close 1009 before either handler saw a byte, and the
/// `inbound.messages(maxSize: 1 << 20)` ceiling both handlers declare was
/// unreachable from outside: `WSCore` measures `maxSize` only while appending
/// *continuation* frames, never the first one.
///
/// These run against a real loopback server through the production
/// `RPCWebSocketHandler.mount`, configured from the production
/// `CrowDaemon.maxWebSocketFrameSize` — a test that hardcoded its own ceiling
/// would stay green while `crowd` kept dropping the connection.
@Suite("WebSocket frame size (CROW-956)", .timeLimit(.minutes(1)))
struct WebSocketFrameSizeTests {
    /// Comfortably past the old 16 KiB default, and the size of a real paste or
    /// a config with a handful of jobs in it.
    private static let payloadBytes = 64 * 1024

    /// Carries the reply and the close code out of the escaping, `@Sendable`
    /// socket handler and the `@Sendable` test closure around it.
    private actor Recorder {
        private(set) var text: String?
        private(set) var closeCode: WebSocketErrorCode?
        func set(_ value: String) { text = value }
        func recordClose(_ frame: WebSocketCloseFrame?) { closeCode = frame?.closeCode }
    }

    /// Production `/rpc`, plus a second route standing in for `/terminal`, on
    /// one upgrade channel — the shape `CrowDaemon.run` builds.
    private func makeApp() -> some ApplicationProtocol {
        // Echoes the byte COUNT, not the payload: the reply then stays far under
        // the client's own decoder ceiling, so a failure here is unambiguously
        // the server's inbound limit and not the test client's.
        let commandRouter = CommandRouter(handlers: [
            "echo-length": { @Sendable params in
                ["length": .int(params["payload"]?.stringValue?.utf8.count ?? -1)]
            }
        ])

        let wsRouter = Router(context: CrowWSContext.self)
        RPCWebSocketHandler.mount(
            on: wsRouter,
            commandRouter: commandRouter,
            eventHub: EventHub(),
            boundHost: "127.0.0.1",
            sessions: SessionStore(),
            // Never read on this path: the peer is loopback with no
            // X-Forwarded-For, so `WebAuthGuard.authorize` short-circuits to
            // "local" without calling its config provider, and `localDirect` is
            // therefore true so `localOnlyDenial` is skipped. Nothing is written
            // to this directory.
            devRoot: NSTemporaryDirectory())

        // Stand-in for `TerminalWebSocket` — see `terminalRouteAcceptsLargePaste`
        // for exactly what this does and does not pin.
        wsRouter.ws("/terminal") { inbound, outbound, _ in
            for try await message in inbound.messages(maxSize: CrowDaemon.maxWebSocketFrameSize) {
                guard case .binary(let buffer) = message else { continue }
                try await outbound.write(.text("\(buffer.readableBytes)"))
                return
            }
        }

        return Application(
            router: Router(context: CrowHTTPContext.self),
            // The line under test — same overload and same constant as
            // `CrowDaemon.run`, deliberately not a literal.
            server: .http1WebSocketUpgrade(
                webSocketRouter: wsRouter,
                configuration: .init(ws: .init(maxFrameSize: CrowDaemon.maxWebSocketFrameSize))),
            configuration: .init(
                address: .hostname("127.0.0.1", port: 0),
                serverName: "crowd-test"))
    }

    /// `closeTimeout` is shortened from the 15 s default so a wedged close
    /// handshake fails fast rather than stalling the suite.
    private var clientConfig: WebSocketClientConfiguration {
        .init(maxFrameSize: CrowDaemon.maxWebSocketFrameSize, closeTimeout: .seconds(5))
    }

    private func requestFrame(id: Int, payload: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = JSONRPCRequest(id: id, method: "echo-length", params: ["payload": .string(payload)])
        return String(decoding: try encoder.encode(request), as: UTF8.self)
    }

    /// Read exactly one reply, then return. `/rpc` stays open for further
    /// requests and `EventHub` pushes, so a loop that ran to completion would
    /// only end when the server closed.
    private func readFirstReply(
        _ inbound: WebSocketInboundStream, into box: Recorder
    ) async throws {
        for try await message in inbound.messages(maxSize: CrowDaemon.maxWebSocketFrameSize) {
            if case .text(let text) = message { await box.set(text) }
            break
        }
    }

    // MARK: - /rpc

    @Test("a 64 KiB single text frame round-trips on /rpc")
    func largeTextFrameRoundTrips() async throws {
        let payload = String(repeating: "x", count: Self.payloadBytes)
        let frame = try requestFrame(id: 1, payload: payload)
        #expect(frame.utf8.count > 1 << 14, "the request must exceed the old default to prove anything")

        let box = Recorder()

        try await makeApp().test(.live) { client in
            let close = try await client.ws("/rpc", configuration: clientConfig) { inbound, outbound, _ in
                // `write(.text(_))` emits ONE unfragmented frame of any size,
                // exactly as a browser does. `writeTextMessage` would instead
                // split at the client's own `maxFrameSize` — and those fragments
                // would slip past a 16 KiB server decoder, making this test pass
                // without the fix.
                try await outbound.write(.text(frame))
                try await readFirstReply(inbound, into: box)
            }
            await box.recordClose(close)
        }

        // Pre-fix this is 1009: NIO's decoder rejected the frame and closed the
        // socket before `RPCWebSocketHandler` was handed a message.
        #expect(await box.closeCode != .messageTooLarge,
                "server closed with 1009 — maxFrameSize is still at its default")

        let text = try #require(await box.text, "no reply — the frame never reached the handler")
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(text.utf8))
        #expect(response.error == nil)
        #expect(response.result?["length"]?.intValue == Self.payloadBytes)
    }

    /// `/rpc` decodes binary frames too (`RPCWebSocketHandler`), and binary is
    /// the opcode xterm.js uses. Same ceiling, other opcode.
    @Test("a 64 KiB single binary frame round-trips on /rpc")
    func largeBinaryFrameRoundTrips() async throws {
        let payload = String(repeating: "y", count: Self.payloadBytes)
        let frame = try requestFrame(id: 2, payload: payload)

        let box = Recorder()

        try await makeApp().test(.live) { client in
            let close = try await client.ws("/rpc", configuration: clientConfig) { inbound, outbound, _ in
                try await outbound.write(.binary(ByteBuffer(string: frame)))
                try await readFirstReply(inbound, into: box)
            }
            await box.recordClose(close)
        }

        #expect(await box.closeCode != .messageTooLarge)
        let text = try #require(await box.text)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(text.utf8))
        #expect(response.result?["length"]?.intValue == Self.payloadBytes)
    }

    // MARK: - /terminal

    /// The `/terminal` companion, and an honest one about its limits.
    ///
    /// `TerminalWebSocket.mount` takes a concrete `TerminalCockpit`, whose init
    /// needs a tmux binary and whose attach spawns a real PTY, so the production
    /// handler cannot run here. What this DOES pin is the whole causal chain
    /// minus the PTY: `maxFrameSize` belongs to the ONE upgrade channel shared
    /// by every route on the ws router, so a second route admitting a 64 KiB
    /// binary frame is precisely the property that was broken for `/terminal` —
    /// a >16 KiB paste killed the socket with 1009 before the handler saw a
    /// keystroke. The stand-in also reads with the same
    /// `inbound.messages(maxSize: CrowDaemon.maxWebSocketFrameSize)` expression
    /// the real handler uses, so it fails too if that ceiling is ever dropped
    /// below the frame ceiling.
    ///
    /// What it does NOT pin: `TerminalWebSocket`'s own body — the PTY write,
    /// control frames, the connection limiter. Those stay uncovered without tmux.
    @Test("a 64 KiB paste reaches a second route on the same upgrade channel")
    func terminalRouteAcceptsLargePaste() async throws {
        let paste = ByteBuffer(bytes: [UInt8](repeating: 0x61, count: Self.payloadBytes))
        let box = Recorder()

        try await makeApp().test(.live) { client in
            let close = try await client.ws("/terminal", configuration: clientConfig) { inbound, outbound, _ in
                try await outbound.write(.binary(paste))
                try await readFirstReply(inbound, into: box)
            }
            await box.recordClose(close)
        }

        #expect(await box.closeCode != .messageTooLarge)
        #expect(await box.text == "\(Self.payloadBytes)")
    }

    // MARK: - Over the ceiling

    /// The other half of the CROW-956 decision: what happens to a message that
    /// exceeds the ceiling even after the raise.
    ///
    /// It still closes with 1009, and that is not a shrug — it is the only thing
    /// this layer can do. A correlated JSON-RPC error is impossible: no `id` was
    /// ever decoded (the message was never assembled), so the only legal reply
    /// would be `id: null`, which the web client treats as a notification and
    /// drops. The diagnosability the ticket asked for is therefore delivered
    /// elsewhere — the client now names close code 1009 instead of reporting a
    /// bare "connection closed", and `RPCWebSocketHandler` logs this path, which
    /// it can do here precisely because a *fragmented* over-limit message throws
    /// into its own read loop (a single over-limit FRAME does not — NIO's
    /// decoder closes the channel below the handler and the inbound stream just
    /// ends, which is why the client-side signal carries that case).
    ///
    /// Sent with `writeTextMessage`, which fragments at the client's own
    /// `maxFrameSize` — every frame is legal, only the reassembled total is not.
    @Test("a fragmented message past the ceiling is refused with 1009, not accepted")
    func oversizedFragmentedMessageIsRefused() async throws {
        let payload = String(repeating: "z", count: CrowDaemon.maxWebSocketFrameSize + 1024)
        let frame = try requestFrame(id: 3, payload: payload)
        let box = Recorder()

        try await makeApp().test(.live) { client in
            let close = try await client.ws("/rpc", configuration: clientConfig) { inbound, outbound, _ in
                try await outbound.writeTextMessage(frame)
                try await readFirstReply(inbound, into: box)
            }
            await box.recordClose(close)
        }

        #expect(await box.closeCode == .messageTooLarge)
        #expect(await box.text == nil, "an over-limit message must not be handled")
    }
}
