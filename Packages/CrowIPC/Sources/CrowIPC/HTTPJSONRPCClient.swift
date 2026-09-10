import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLSession live here on Linux
#endif

/// One-shot JSON-RPC over `POST /rpc` — the CLI fallback when the Unix socket is
/// unreachable (CROW-1220).
///
/// Cursor (and other OS-sandboxed harnesses) often refuse `AF_UNIX` to
/// `~/.local/share/crow/crow.sock` while still allowing loopback TCP. `crowd`
/// already serves the same `CommandRouter` at `/rpc` over WebSocket; this
/// client speaks the same JSON-RPC objects as ``SocketClient`` on a single
/// HTTP POST so the CLI does not need a WebSocket stack.
///
/// Security is the daemon's: Origin-empty native clients on loopback are
/// `local-direct` (the same bar as a missing-Origin WS upgrade). The CLI
/// never sends `Origin`.
public struct HTTPJSONRPCClient: Sendable {
    public let url: URL

    /// Default loopback endpoint, matching `crowd`'s `--http-port` default.
    public static let defaultPort = 8787

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
    }

    /// Resolve the fallback URL from the environment.
    ///
    /// - `CROW_HTTP_URL` — full URL (path defaults to `/rpc` when absent).
    /// - else `http://127.0.0.1:${CROW_HTTP_PORT:-8787}/rpc`.
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = environment["CROW_HTTP_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty, let parsed = URL(string: raw) {
            if parsed.path.isEmpty || parsed.path == "/" {
                return parsed.appendingPathComponent("rpc")
            }
            return parsed
        }
        let port = environment["CROW_HTTP_PORT"].flatMap(Int.init) ?? defaultPort
        return URL(string: "http://127.0.0.1:\(port)/rpc")!
    }

    /// Whether a failed Unix-socket connect should try HTTP.
    ///
    /// An explicit `CROW_SOCKET` means the caller pinned a path (tests, a
    /// custom daemon) — do not surprise them with a second transport unless
    /// they also set `CROW_HTTP_URL` / `CROW_HTTP_PORT`.
    public static func shouldFallback(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["CROW_HTTP_URL"] != nil || environment["CROW_HTTP_PORT"] != nil {
            return true
        }
        if environment["CROW_SOCKET"] != nil { return false }
        return true
    }

    /// Send a JSON-RPC request and decode the response body.
    public func send(
        method: String,
        params: [String: JSONValue] = [:],
        timeoutSeconds: Int = SocketClient.readTimeoutSeconds
    ) throws -> JSONRPCResponse {
        let urlRequest = try makeURLRequest(method: method, params: params, timeoutSeconds: timeoutSeconds)
        let (data, http) = try perform(urlRequest)
        if http.statusCode == 401 || http.statusCode == 403 {
            throw HTTPJSONRPCError.httpStatus(http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPJSONRPCError.httpStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        } catch {
            throw HTTPJSONRPCError.decodeFailed
        }
    }

    /// Fire-and-forget: POST and wait only until the request is accepted, then
    /// drop the body. Used by `crow hook-event` so a sandboxed hook still
    /// delivers when the Unix socket is blocked.
    public func post(method: String, params: [String: JSONValue] = [:]) throws {
        let urlRequest = try makeURLRequest(
            method: method, params: params, timeoutSeconds: SocketClient.readTimeoutSeconds)
        _ = try perform(urlRequest)
    }

    private func makeURLRequest(
        method: String,
        params: [String: JSONValue],
        timeoutSeconds: Int
    ) throws -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: TimeInterval(timeoutSeconds))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // No Origin — native client. Browsers always send Origin; the daemon
        // Origin-checks POST /rpc the same way it checks the WS upgrade.
        let rpc = JSONRPCRequest(id: 1, method: method, params: params.isEmpty ? nil : params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        req.httpBody = try encoder.encode(rpc)
        return req
    }

    private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let box = URLSessionBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            box.finish(data: data, response: response, error: error)
        }
        task.resume()
        let timeout = request.timeoutInterval + 1
        guard box.wait(timeout: timeout) else {
            task.cancel()
            throw HTTPJSONRPCError.timeout
        }
        if let error = box.error {
            throw HTTPJSONRPCError.connectionFailed(error.localizedDescription)
        }
        guard let data = box.data, let http = box.response as? HTTPURLResponse else {
            throw HTTPJSONRPCError.connectionFailed("empty response")
        }
        return (data, http)
    }
}

/// Errors from the loopback HTTP JSON-RPC fallback (CROW-1220).
public enum HTTPJSONRPCError: Error, LocalizedError {
    case connectionFailed(String)
    case httpStatus(Int)
    case decodeFailed
    case timeout

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let detail):
            "HTTP /rpc connection failed: \(detail)"
        case .httpStatus(let code):
            "HTTP /rpc returned status \(code)"
        case .decodeFailed:
            "HTTP /rpc returned a body that was not JSON-RPC"
        case .timeout:
            "HTTP /rpc timed out"
        }
    }

    /// True when no HTTP peer answered — `crow hook-event` treats this like a
    /// missing Unix socket (silent no-op).
    public var isConnectFailure: Bool {
        switch self {
        case .connectionFailed, .timeout: true
        default: false
        }
    }
}

/// Sync latch around `URLSession.dataTask`. `URLSession.shared.data(for:)` is
/// async-only; the CLI `rpc()` surface is synchronous.
private final class URLSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    var data: Data?
    var response: URLResponse?
    var error: Error?

    func finish(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        self.data = data
        self.response = response
        self.error = error
        lock.unlock()
        done.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        done.wait(timeout: .now() + timeout) == .success
    }
}
