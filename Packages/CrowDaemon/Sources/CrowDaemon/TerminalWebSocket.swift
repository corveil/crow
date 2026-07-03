import CrowTerminal
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Streams a PTY running `tmux attach-session` to xterm.js over a WebSocket
/// (`/terminal`). Replaces the macOS WKWebView message bus with the same
/// message types: raw PTY bytes out (binary frames), keystrokes in (binary
/// frames), and JSON control frames — `resize` and `select-window` (CROW-581).
enum TerminalWebSocket {
    static func mount(on router: Router<BasicWebSocketRequestContext>, cockpit: TerminalCockpit) {
        router.ws("/terminal") { request, _ in
            // Reject cross-site upgrades — a plain attach yields an interactive
            // shell, so an unguarded upgrade is effectively RCE (CROW-581 review).
            WebSocketOriginGuard.isAllowedOrigin(request.headers[.origin]) ? .upgrade() : .dontUpgrade
        } onUpgrade: { inbound, outbound, _ in
            // Bound concurrent PTY + tmux attaches.
            guard TerminalConnectionLimiter.shared.acquire() else {
                try? await outbound.write(.text("[crow] terminal connection limit reached"))
                return
            }
            defer { TerminalConnectionLimiter.shared.release() }

            // deliverOnMainQueue: false — the daemon has no main run loop, so PTY
            // output is delivered synchronously on the PTY read queue and bridged
            // into this async task via an AsyncStream.
            let pty = PTYProcess(deliverOnMainQueue: false)
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            pty.onOutput = { data in continuation.yield(data) }
            pty.onExit = { _ in continuation.finish() }

            do {
                try pty.start(command: cockpit.attachCommand(), workingDirectory: nil)
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
                        // Single shared cockpit: switch the attached client's
                        // visible window in place, mirroring the desktop's
                        // `makeActive` → `select-window` on tab switch.
                        if let window = control.window {
                            try? cockpit.controller.selectWindow(index: window)
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
