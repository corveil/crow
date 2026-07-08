import CrowCore
import CrowPersistence
import CrowTerminal
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Streams a PTY attached to a private grouped view of the shared tmux cockpit
/// to xterm.js over a WebSocket (`/terminal`). Replaces the macOS WKWebView
/// message bus with the same message types: raw PTY bytes out (binary), input
/// in (binary), and JSON control frames — `resize` and `select-window`.
///
/// Each connection opens its own grouped tmux session, so `select-window` shows
/// the chosen window without disturbing any other client — including the
/// running desktop app, which shares the same cockpit (CROW-581).
enum TerminalWebSocket {
    static func mount(on router: Router<CrowWSContext>, cockpit: TerminalCockpit, boundHost: String, sessions: SessionStore, devRoot: String) {
        router.ws("/terminal") { request, context in
            // Reject cross-site upgrades AND unauthenticated non-local access — a
            // plain attach yields an interactive shell, so an unguarded upgrade is
            // effectively RCE (CROW-581 review, CROW-593).
            let originOK = WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
            let auth = WebAuthGuard.authorize(
                remoteAddress: context.remoteAddress,
                cookieHeader: request.headers[.cookie],
                forwardedFor: request.headers[HTTPField.Name("x-forwarded-for")!],
                forwardedProto: request.headers[HTTPField.Name("x-forwarded-proto")!],
                configProvider: { ConfigStore.loadConfig(devRoot: devRoot) },
                sessions: sessions)
            return (originOK && auth.isAuthorized) ? .upgrade() : .dontUpgrade
        } onUpgrade: { inbound, outbound, _ in
            // Bound concurrent PTY + tmux attaches.
            guard TerminalConnectionLimiter.shared.acquire() else {
                try? await outbound.write(.text("[crow] terminal connection limit reached"))
                return
            }
            defer { TerminalConnectionLimiter.shared.release() }

            // Private grouped view of the cockpit — independent current-window,
            // torn down when the browser disconnects.
            let group = cockpit.openViewSession()
            defer { cockpit.closeViewSession(group) }

            // deliverOnMainQueue: false — the daemon has no main run loop, so PTY
            // output is delivered synchronously on the PTY read queue and bridged
            // into this async task via an AsyncStream.
            let pty = PTYProcess(deliverOnMainQueue: false)
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            pty.onOutput = { data in continuation.yield(data) }
            pty.onExit = { _ in continuation.finish() }

            do {
                try pty.start(command: cockpit.attachCommand(group: group), workingDirectory: nil)
            } catch {
                continuation.finish()
                return
            }

            // Pump PTY output → binary WebSocket frames.
            let outputTask = Task {
                for await chunk in stream {
                    try await outbound.write(.binary(ByteBuffer(bytes: chunk)))
                }
            }
            defer {
                pty.terminate()
                continuation.finish()
                outputTask.cancel()
            }

            // Inbound: binary = keystrokes → PTY; text = JSON control frame.
            for try await message in inbound.messages(maxSize: 1 << 20) {
                switch message {
                case .binary(let buffer):
                    pty.write(Data(buffer.readableBytesView))
                case .text(let text):
                    guard let data = text.data(using: .utf8),
                          let control = try? JSONDecoder().decode(TerminalControl.self, from: data) else { continue }
                    switch control.type {
                    case "resize":
                        // Floor at 1×1 so a zero/negative request can't drive a
                        // degenerate tmux resize (CROW-581 review).
                        pty.resize(
                            rows: UInt16(clamping: max(1, control.rows ?? 24)),
                            cols: UInt16(clamping: max(1, control.cols ?? 80)))
                    case "select-window":
                        // Switch this browser's grouped view to the window; other
                        // clients (incl. the desktop app) keep their own view.
                        if let window = control.window {
                            cockpit.selectWindow(group: group, index: window)
                        }
                    default:
                        break
                    }
                }
            }
        }
    }
}

private struct TerminalControl: Decodable {
    let type: String
    let rows: Int?
    let cols: Int?
    let window: Int?
}
