import CrowIPC
import ArgumentParser
import Foundation

/// Send a JSON-RPC request to the running Crow app.
///
/// Prefers the Unix socket at `crow.sock`. When that connect fails (sandbox
/// policy, stale file) and HTTP fallback is allowed, retries over loopback
/// `POST /rpc` (CROW-1220) so Cursor and other sandboxed harnesses can still
/// reach a listening `crowd` without the operator disabling the sandbox.
///
/// - Parameters:
///   - method: The RPC method name (e.g., "new-session").
///   - params: Key-value parameters for the RPC call.
///   - timeoutSeconds: Read timeout for the response (default 30).
/// - Returns: The result dictionary from the server response.
/// - Throws: `ValidationError` if the server returns an error or both
///   transports fail.
public func rpc(_ method: String, params: [String: JSONValue] = [:], timeoutSeconds: Int = 30) throws -> [String: JSONValue] {
    do {
        return try unwrapRPC(try SocketClient().send(
            method: method, params: params, timeoutSeconds: timeoutSeconds))
    } catch let socketError as SocketError where socketError.isConnectFailure {
        guard HTTPJSONRPCClient.shouldFallback() else { throw socketError }
        do {
            return try unwrapRPC(try HTTPJSONRPCClient().send(
                method: method, params: params, timeoutSeconds: timeoutSeconds))
        } catch {
            throw ValidationError(
                "\(error.localizedDescription) (Unix socket also failed: \(socketError.localizedDescription))"
            )
        }
    }
}

/// Fire-and-forget a JSON-RPC request to the running Crow app.
///
/// Writes the request and returns without reading a response, so the agent
/// doesn't wait on the daemon's reply: the app still processes the event once
/// its serialized MainActor frees, but a busy daemon can't stall the hook up to
/// its timeout (#903). See `SocketClient.post` for the one residual wait — a
/// payload past the socket send buffer can still block in `write()` until the
/// daemon drains it.
///
/// Falls back to `POST /rpc` when the Unix socket is unreachable and HTTP
/// fallback is allowed (CROW-1220), matching ``rpc``.
///
/// - Throws: `SocketError.connectionFailed` when the app isn't running (callers
///   treat this as an expected no-op); other socket errors propagate.
public func rpcNotify(_ method: String, params: [String: JSONValue] = [:]) throws {
    do {
        try SocketClient().post(method: method, params: params)
    } catch let error as SocketError where error.isConnectFailure {
        guard HTTPJSONRPCClient.shouldFallback() else { throw error }
        do {
            try HTTPJSONRPCClient().post(method: method, params: params)
        } catch let http as HTTPJSONRPCError where http.isConnectFailure {
            throw error
        }
    }
}

private func unwrapRPC(_ response: JSONRPCResponse) throws -> [String: JSONValue] {
    if let error = response.error {
        throw ValidationError("Error \(error.code): \(error.message)")
    }
    return response.result ?? [:]
}

/// Pretty-print a JSON dictionary to stdout with sorted keys.
public func printJSON(_ dict: [String: JSONValue]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(dict), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

/// Write a non-fatal advisory to stderr. Kept off stdout so the "every command
/// prints JSON to stdout" contract holds and pipelines stay parseable.
public func warn(_ message: String) {
    FileHandle.standardError.write(Data("crow: warning: \(message)\n".utf8))
}
