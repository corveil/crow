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

/// Pretty-print a JSON dictionary to stdout with sorted keys.
public func printJSON(_ dict: [String: JSONValue]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(dict), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}
