import CrowIPC
import ArgumentParser
import Foundation

/// Send a JSON-RPC request to the running Crow app via Unix socket.
///
/// - Parameters:
///   - method: The RPC method name (e.g., "new-session").
///   - params: Key-value parameters for the RPC call.
///   - timeoutSeconds: Read timeout for the response (default 30).
/// - Returns: The result dictionary from the server response.
/// - Throws: `ValidationError` if the server returns an error or the socket connection fails.
public func rpc(_ method: String, params: [String: JSONValue] = [:], timeoutSeconds: Int = 30) throws -> [String: JSONValue] {
    let client = SocketClient()
    let response = try client.send(method: method, params: params, timeoutSeconds: timeoutSeconds)
    if let error = response.error {
        throw ValidationError("Error \(error.code): \(error.message)")
    }
    return response.result ?? [:]
}

/// Fire-and-forget a JSON-RPC request to the running Crow app via Unix socket.
///
/// Writes the request and returns immediately without reading a response. Used
/// by hooks (`crow hook-event`): the app still processes the event once its
/// serialized MainActor frees, but the agent never waits, so a busy daemon
/// can't stall the hook up to its timeout (#903).
///
/// - Throws: `SocketError.connectionFailed` when the app isn't running (callers
///   treat this as an expected no-op); other socket errors propagate.
public func rpcNotify(_ method: String, params: [String: JSONValue] = [:]) throws {
    try SocketClient().post(method: method, params: params)
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
