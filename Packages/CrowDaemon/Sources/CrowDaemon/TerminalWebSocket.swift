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
            do {
                for try await message in inbound.messages(maxSize: CrowDaemon.maxWebSocketFrameSize) {
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
                                // Re-arm the pane's mouse-tracking mode (CROW-1043).
                                // The in-place agent switch (CROW-1035) clears the
                                // xterm buffer before this select without a full
                                // `term.reset()` — see `clearTermBuffer` in app.js.
                                // so an agent→agent switch (same mouse state) restores
                                // no DECSET and the forwarded wheel goes dead until a
                                // full Reload. Re-sending the pane's actual mouse mode
                                // fixes the wheel deterministically; it's inert on a
                                // plain shell (`swallowMouseMode` drops it). Yielded
                                // through the same stream as the replay/live output so
                                // it serializes on the single `outputTask`.
                                if let reArm = cockpit.mouseModeReArmData(group: group, index: window) {
                                    continuation.yield(reArm)
                                }
                                // Replay the pane's tmux scrollback into the xterm buffer
                                // so history survives a crowd restart / browser reload —
                                // the client re-selects its window on every reconnect and
                                // tab switch (CROW-606). Alt-buffer panes skip the replay
                                // (CROW-1035): capture-pane returns only the current
                                // frame, and injecting it races the live attach redraw.
                                // Yield through the same stream the PTY writes to, so this
                                // serializes with live output on the single `outputTask`
                                // (no concurrent `outbound` writes). In-place agent switches
                                // pass `replay: false` (CROW-1035): the live attach already
                                // has the frame and a capture-pane dump stacks inline chrome.
                                if control.replay != false,
                                   let replay = cockpit.replayData(group: group, index: window) {
                                    continuation.yield(replay)
                                }
                            }
                        default:
                            break
                        }
                    }
                }
            } catch {
                // CROW-956, same rule and same measured scope as `/rpc`: a normal
                // disconnect ends the sequence without throwing, so this stays
                // quiet for an ordinary browser close, and cancellation is our own
                // teardown. It catches a *fragmented* message over the ceiling,
                // not a single oversized FRAME — NIO closes that one below this
                // handler, leaving the client's close code as its only signal.
                //
                // The only client message big enough to reach either path here is
                // a paste: `sendToPTY` ships the whole clipboard in one frame,
                // which at the old 16 KiB default made a large paste vanish in
                // silence — the socket died with 1009 and the client reconnected
                // as if nothing had happened.
                if !(error is CancellationError) {
                    CrowDaemon.log(
                        "WARNING: /terminal read ended abnormally (per-message limit "
                        + "\(CrowDaemon.maxWebSocketFrameSize) bytes) — PTY detached: \(error)")
                }
                // Rethrow: this is purely an observation point. `WSCore` turns
                // the error into the close code the client sees, and swallowing
                // it here would silently downgrade a 1009 to a normal close.
                throw error
            }
        }
    }
}

private struct TerminalControl: Decodable {
    let type: String
    let rows: Int?
    let cols: Int?
    let window: Int?
    /// When `false`, skip the CROW-606 capture-pane replay. In-place agent tab
    /// switches send this — the live attach already has the frame and replay
    /// races it (CROW-1035). Omitted or `true` keeps connect/reload/heal behavior.
    let replay: Bool?
}
