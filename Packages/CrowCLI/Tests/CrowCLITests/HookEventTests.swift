import Testing
import Foundation
import CrowIPC
@testable import CrowCLILib

// MARK: - Hook Event Payload Parsing

@Test func parseValidJSONPayload() throws {
    let json = #"{"key": "value", "num": 42}"#
    let data = json.data(using: .utf8)!

    let payload = parseHookPayload(from: data)

    #expect(payload["key"]?.stringValue == "value")
    #expect(payload["num"]?.intValue == 42)
}

@Test func parseEmptyDataReturnsEmptyPayload() {
    let payload = parseHookPayload(from: Data())
    #expect(payload.isEmpty)
}

@Test func parseMalformedJSONReturnsEmptyPayload() {
    let data = "not valid json".data(using: .utf8)!
    let payload = parseHookPayload(from: data)
    #expect(payload.isEmpty)
}

@Test func parseNestedJSONPayload() throws {
    let json = #"{"event": "Stop", "data": {"reason": "user"}}"#
    let data = json.data(using: .utf8)!

    let payload = parseHookPayload(from: data)

    #expect(payload["event"]?.stringValue == "Stop")
    if case .object(let nested) = payload["data"] {
        #expect(nested["reason"]?.stringValue == "user")
    } else {
        Issue.record("Expected nested object for 'data' key")
    }
}

@Test func parseArrayPayloadFails() {
    // hook-event expects a dictionary, not an array
    let json = #"[1, 2, 3]"#
    let data = json.data(using: .utf8)!

    let payload = parseHookPayload(from: data)
    #expect(payload.isEmpty)
}

// MARK: - Connection Refused Handling

/// Regression test for #227: when the Crow app is not running, the hook-event
/// command must silently no-op instead of exiting non-zero. Otherwise Claude
/// Code surfaces "Stop hook error: …" on every session exit.
@Test func forwardHookEventSilentWhenAppNotRunning() throws {
    let nonExistent = NSTemporaryDirectory() + "crow-test-\(UUID().uuidString).sock"
    setenv("CROW_SOCKET", nonExistent, 1)
    defer { unsetenv("CROW_SOCKET") }

    try forwardHookEvent(params: [
        "session_id": .string(UUID().uuidString),
        "event_name": .string("Stop"),
        "payload": .object([:]),
    ])
}

/// #903: `forwardHookEvent` must be wired to the fire-and-forget path, not a
/// blocking round-trip. Against a live daemon whose handler never replies within
/// the test, `rpc` would hang on the read until the socket timeout; `rpcNotify`
/// returns as soon as the request is written. Reverting the call site back to
/// `rpc` fails here — which the absent-socket test above cannot catch, since it
/// never reaches the read.
@Test func forwardHookEventDoesNotBlockOnSlowDaemon() throws {
    let path = NSTemporaryDirectory() + "crow-test-\(UUID().uuidString).sock"
    let router = CommandRouter(handlers: [
        "hook-event": { @Sendable _ in
            try await Task.sleep(nanoseconds: 60_000_000_000) // 60s — never replies in test
            return [:]
        },
    ])
    let server = SocketServer(socketPath: path, router: router)
    try server.start()
    defer { server.stop(); try? FileManager.default.removeItem(atPath: path) }
    Thread.sleep(forTimeInterval: 0.05) // let the accept loop come up

    setenv("CROW_SOCKET", path, 1)
    defer { unsetenv("CROW_SOCKET") }

    let start = Date()
    try forwardHookEvent(params: [
        "event_name": .string("PreToolUse"),
        "payload": .object([:]),
    ])
    #expect(Date().timeIntervalSince(start) < 5)
}
