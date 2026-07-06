import Foundation
import CrowCore
import CrowIPC

enum CrowdClientError: Error {
    case notConnected
    case rpc(String)
    case disconnected
}

/// The macOS app's connection to a running `crowd` daemon (ADR 0007; CROW-581,
/// Stage 3/F). A single persistent `/rpc` WebSocket — the same wire the web
/// client speaks: JSON-RPC correlated by `id`, plus a server-pushed `changed`
/// notification that triggers a full `get-state` re-hydrate of `appState`.
///
/// **Connect-only:** the user launches `crowd`; this client attaches to it and
/// auto-reconnects if the socket drops. It never spawns or supervises the daemon.
/// Session/lifecycle actions are sent as RPCs; terminal I/O stays host-side (the
/// app attaches to the shared tmux server directly).
@MainActor
final class CrowdClient {
    private let appState: AppState
    private let rpcURL: URL
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: JSONValue], Error>] = [:]
    private var closed = false

    /// Fired on the main actor after each successful `get-state` hydrate. The app
    /// uses this in client mode to adopt crowd's tmux windows for rendering
    /// (Stage 3b/F).
    var onHydrated: (@MainActor () -> Void)?

    /// Resolve `crowd`'s `/rpc` URL. Defaults to loopback:8787 (the daemon's
    /// default HTTP port); override with `CROW_DAEMON_URL` (a full `ws://…/rpc`).
    static func defaultURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["CROW_DAEMON_URL"],
           let url = URL(string: override) {
            return url
        }
        return URL(string: "ws://127.0.0.1:8787/rpc")!
    }

    init(appState: AppState, url: URL = CrowdClient.defaultURL()) {
        self.appState = appState
        self.rpcURL = url
    }

    // MARK: Lifecycle

    func connect() {
        closed = false
        openSocket()
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func openSocket() {
        let socket = session.webSocketTask(with: rpcURL)
        task = socket
        socket.resume()
        receiveLoop(socket)
        Task { await self.hydrate() }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === socket else { return }
                switch result {
                case .failure:
                    self.handleDisconnect()
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveLoop(socket)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        // Server-initiated `changed` nudge (id == null) → re-hydrate.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (obj["id"] == nil || obj["id"] is NSNull),
           obj["method"] as? String == "changed" {
            Task { await self.hydrate() }
            return
        }
        // Correlated response.
        guard let resp = try? JSONDecoder().decode(JSONRPCResponse.self, from: data),
              let cont = pending.removeValue(forKey: resp.id) else { return }
        if let error = resp.error {
            cont.resume(throwing: CrowdClientError.rpc(error.message))
        } else {
            cont.resume(returning: resp.result ?? [:])
        }
    }

    private func handleDisconnect() {
        for (_, cont) in pending { cont.resume(throwing: CrowdClientError.disconnected) }
        pending.removeAll()
        task = nil
        guard !closed else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s backoff, matches the web client
            if !self.closed { self.openSocket() }
        }
    }

    // MARK: RPC

    /// Send a JSON-RPC request and await its correlated result. Fire-and-forget
    /// callers can ignore the return value.
    @discardableResult
    func rpc(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> [String: JSONValue] {
        guard let socket = task else { throw CrowdClientError.notConnected }
        let id = nextID
        nextID += 1
        let request = JSONRPCRequest(id: id, method: method, params: params.isEmpty ? nil : params)
        let text = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            socket.send(.string(text)) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    if let waiting = self?.pending.removeValue(forKey: id) { waiting.resume(throwing: error) }
                }
            }
        }
    }

    /// Fire an action RPC without blocking the UI; log failures.
    func send(_ method: String, _ params: [String: JSONValue] = [:]) {
        Task { @MainActor in
            do { _ = try await rpc(method, params) }
            catch { NSLog("[CrowdClient] %@ failed: %@", method, String(describing: error)) }
        }
    }

    // MARK: State hydration

    /// Rebuild `appState` from a single `get-state` snapshot. Called on connect
    /// and on every `changed` push.
    func hydrate() async {
        do {
            let result = try await rpc("get-state")
            let data = try JSONEncoder().encode(result)
            let snapshot = try JSONDecoder().decode(DaemonStateSnapshot.self, from: data)
            appState.apply(snapshot)
            onHydrated?()
        } catch {
            NSLog("[CrowdClient] hydrate failed: %@", String(describing: error))
        }
    }
}
