import Testing
import Foundation
import CrowIPC
@testable import CrowCLILib

/// Sync-settable, async-readable latch. `DispatchSemaphore.wait()` is
/// unavailable in async contexts, so a parked hook handler polls this instead
/// of blocking — the test releases it synchronously from a `defer`.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.lock(); open = true; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
}

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

/// Both tests mutate the process-global `CROW_SOCKET` env var, which
/// `SocketClient` reads. Swift Testing parallelizes by default and `make test`
/// doesn't pass `--no-parallel`, so without `.serialized` these two would race
/// each other's `setenv`/`unsetenv` — both a data race against another thread's
/// `environ` read, and a correctness hole: if the absent-socket test's `setenv`
/// landed between this suite's other test's `setenv` and its `forwardHookEvent`,
/// the fire-and-forget gate would connect to the nonexistent path, no-op, and
/// pass vacuously. Serializing the suite closes both.
@Suite(.serialized)
struct HookEventForwarding {

    /// Regression test for #227: when the Crow app is not running, the
    /// hook-event command must silently no-op instead of exiting non-zero.
    /// Otherwise Claude Code surfaces "Stop hook error: …" on every session exit.
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
    /// blocking round-trip. The handler signals receipt and then parks until the
    /// test releases it, so a reintroduced `rpc` read would block here while
    /// `rpcNotify` returns as soon as the request is written. Asserts both that
    /// `forwardHookEvent` returns before the handler replies *and* that the
    /// daemon still received the event — so it can't pass by silently no-op'ing
    /// (which is why it lives in the serialized suite above).
    @Test func forwardHookEventDoesNotBlockOnSlowDaemon() throws {
        let received = DispatchSemaphore(value: 0)
        let latch = Latch()
        let path = NSTemporaryDirectory() + "crow-test-\(UUID().uuidString).sock"
        let router = CommandRouter(handlers: [
            "hook-event": { @Sendable _ in
                received.signal()
                // Park (without replying) until the test releases us, so a
                // reintroduced `rpc` read would stall here. Polling a latch, not
                // a 60s sleep — the handler returns within a poll of release, so
                // it doesn't pin a socket worker for the rest of the run.
                while !latch.isOpen { try await Task.sleep(nanoseconds: 20_000_000) }
                return [:]
            },
        ])
        let server = SocketServer(socketPath: path, router: router)
        try server.start()
        // Release the parked handler first so `server.stop()` isn't waiting on it.
        defer { latch.release(); server.stop(); try? FileManager.default.removeItem(atPath: path) }
        Thread.sleep(forTimeInterval: 0.05) // let the accept loop come up

        setenv("CROW_SOCKET", path, 1)
        defer { unsetenv("CROW_SOCKET") }

        let start = Date()
        try forwardHookEvent(params: [
            "event_name": .string("PreToolUse"),
            "payload": .object([:]),
        ])
        #expect(Date().timeIntervalSince(start) < 5) // returned before the handler's (parked) reply
        #expect(received.wait(timeout: .now() + 2) == .success) // and the daemon still got it
    }
}
