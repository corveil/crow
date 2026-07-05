import Foundation

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

    /// Current subscriber count — for tests/diagnostics.
    var subscriberCount: Int { subscribers.count }
}
