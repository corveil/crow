import Foundation
import CrowCore

/// Fan-out hub for server-initiated `/rpc` WebSocket notifications. Each
/// connected client registers its own per-connection outbound continuation;
/// the daemon calls `broadcast` when its state moves (store reload, board poll)
/// so clients re-fetch reactively instead of waiting for their interval poll
/// (CROW-581, M-D).
///
/// Fan-IN, not fan-out-to-sockets: the hub only *yields* into continuations the
/// connections own. Each connection drains its single stream to `outbound` from
/// one writer task, so RPC responses and these notifications never race on the
/// same socket.
actor EventHub {
    /// A pre-encoded JSON-RPC notification (no `id`) meaning "state may have
    /// changed — re-fetch". Clients that don't recognize it ignore it (no `id`
    /// to correlate), so broadcasting is safe even to older web builds.
    static let changedFrame = #"{"jsonrpc":"2.0","method":"changed"}"#

    private var subscribers: [UUID: AsyncStream<String>.Continuation] = [:]

    /// Register a connection's outbound continuation. Returns a token to pass to
    /// `unsubscribe` when the socket closes. The hub does not own the stream's
    /// lifetime — the connection finishes it on disconnect.
    func subscribe(_ continuation: AsyncStream<String>.Continuation) -> UUID {
        let id = UUID()
        subscribers[id] = continuation
        return id
    }

    func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    /// Yield a raw JSON text frame to every subscriber. Yielding to a finished
    /// continuation is a harmless no-op, so a disconnect racing a broadcast is
    /// safe.
    func broadcast(_ text: String = changedFrame) {
        for continuation in subscribers.values {
            continuation.yield(text)
        }
    }

    /// Broadcast an automation notification. See `notifyFrame`.
    func broadcastNotification(
        event: NotificationEvent,
        key: String,
        title: String,
        body: String
    ) {
        broadcast(Self.notifyFrame(event: event, key: key, title: title, body: body))
    }

    /// Current subscriber count — for tests/diagnostics.
    var subscriberCount: Int { subscribers.count }

    /// A pre-encoded JSON-RPC notification carrying one of Crow's own automation
    /// events (CROW-768) — the moments a watcher acted on the user's behalf, which
    /// no client can derive from polled state. Like `changedFrame` it carries no
    /// `id`, so clients that don't know the method ignore it.
    ///
    /// `key` is the client-side dedup/navigation key: the session UUID where one
    /// exists, otherwise the issue URL (auto-workspace) or a stable literal
    /// (`"config"`). Encoded through `JSONEncoder` so a title/body containing
    /// quotes or backslashes can't produce a malformed frame.
    static func notifyFrame(
        event: NotificationEvent,
        key: String,
        title: String,
        body: String
    ) -> String {
        struct Params: Encodable {
            let event: String
            let key: String
            let title: String
            let body: String
        }
        struct Frame: Encodable {
            let jsonrpc = "2.0"
            let method = "notify"
            let params: Params
        }
        let frame = Frame(params: Params(
            event: event.rawValue, key: key, title: title, body: body))
        let encoder = JSONEncoder()
        // Deterministic key order — nothing parses these frames positionally, but
        // a stable string keeps logs and tests comparable.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(frame),
              let text = String(data: data, encoding: .utf8) else {
            // Encoding a fixed-shape struct of Strings can't realistically fail;
            // fall back to the plain nudge so the client at least re-fetches.
            return changedFrame
        }
        return text
    }

    /// Metadata-only TUI recording notification (CROW-1255). No `id`, so old
    /// clients ignore it. No PTY bytes — the payload is ids + a greppable
    /// signature; `app.js` filters on `session_id` (HUD) or `recording_id`
    /// (playback route).
    static func tuiRecordEventFrame(
        recordingID: UUID,
        sessionID: UUID?,
        t: Int,
        kind: String,
        severity: String,
        signature: String,
        grid: [String: [Int]]?
    ) -> String {
        struct Grid: Encodable {
            var pty: [Int]?
            var css: [Int]?
        }
        struct Params: Encodable {
            var recording_id: String
            var session_id: String?
            var t: Int
            var kind: String
            var severity: String
            var signature: String
            var grid: Grid?
        }
        struct Frame: Encodable {
            let jsonrpc = "2.0"
            let method = "tui-record-event"
            let params: Params
        }
        let gridObj = grid.map { Grid(pty: $0["pty"], css: $0["css"]) }
        let frame = Frame(params: Params(
            recording_id: recordingID.uuidString,
            session_id: sessionID?.uuidString,
            t: t, kind: kind, severity: severity, signature: signature,
            grid: gridObj))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(frame),
              let text = String(data: data, encoding: .utf8) else {
            return changedFrame
        }
        return text
    }
}
