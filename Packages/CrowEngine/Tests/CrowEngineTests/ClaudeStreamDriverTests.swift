import Foundation
import Testing
@testable import CrowEngine

/// Experimental headless driver. The child is a `/bin/sh` script that speaks the
/// stream-json protocol shape observed from Claude Code 2.1.309 — no real
/// `claude` runs here.
@Suite struct ClaudeStreamDriverTests {
    @Test func classifyMapsProtocolLines() {
        func c(_ s: String) -> ClaudeStreamDriver.Event? { ClaudeStreamDriver.classify(Data(s.utf8)) }
        #expect(c(#"{"type":"system","subtype":"init","session_id":"abc"}"#) == .conversationStarted(id: "abc"))
        #expect(c(#"{"type":"system","subtype":"status"}"#) == nil)
        #expect(c(#"{"type":"result","subtype":"success","is_error":false}"#) == .turnEnded(isError: false))
        #expect(c(#"{"type":"stream_event","event":{"type":"content_block_delta"}}"#) == nil)
        #expect(c("garbage") == nil)
        let req = c(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/w/hello.txt","content":"hi"}}}"#)
        guard case .permissionRequested(let p)? = req else {
            Issue.record("expected a permission request, got \(String(describing: req))")
            return
        }
        #expect(p.requestID == "r1")
        #expect(p.toolName == "Write")
        #expect(p.summary == "/w/hello.txt")
        #expect(p.inputJSON.contains("hello.txt"))
    }

    @Test func usageFoldsAssistantTokensAndResultWindow() {
        var u = ClaudeStreamDriver.Usage()
        func feed(_ s: String) { ClaudeStreamDriver.updateUsage(&u, from: Data(s.utf8)) }
        // Shapes captured from Claude Code 2.1.309 stream-json.
        feed(#"{"type":"assistant","parent_tool_use_id":null,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":4866,"cache_read_input_tokens":41788,"output_tokens":1}}}"#)
        feed(#"{"type":"assistant","parent_tool_use_id":"toolu_1","message":{"model":"claude-haiku-5-5","usage":{"input_tokens":99999}}}"#)
        #expect(u.usedTokens == 46_656)
        #expect(u.model == "claude-opus-5-5")
        #expect(u.contextWindow == nil)
        feed(#"{"type":"result","total_cost_usd":0.0098,"modelUsage":{"claude-haiku-5-5":{"contextWindow":200000},"claude-opus-5-5[1m]":{"contextWindow":1000000}}}"#)
        #expect(u.contextWindow == 1_000_000)
        #expect(u.costUSD == 0.0098)
    }

    @Test func defaultCommandRoutesPermissionsToTheHost() {
        let (exe, args) = ClaudeStreamDriver.defaultCommand(claudePath: "/opt/claude", resumeID: "c1")
        #expect(exe == "/bin/zsh")
        // Without `--permission-prompt-tool stdio`, `--permission-prompts host`
        // auto-denies instead of asking (observed on 2.1.309).
        let joined = args.joined(separator: " ")
        #expect(joined.contains("--permission-prompts host --permission-prompt-tool stdio"))
        #expect(joined.contains("--input-format stream-json --output-format stream-json"))
        #expect(args.suffix(2) == ["--resume", "c1"])
    }

    @Test func driverRoundTripsATurnWithAPermissionPrompt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("s.ndjson")

        // init → (read user) → can_use_tool → (read control_response) → result → exit on EOF.
        let script = #"""
        echo '{"type":"system","subtype":"init","session_id":"conv-1"}'
        read -r user
        echo '{"type":"stream_event","event":{"type":"message_start"}}'
        echo '{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"/w/a.txt"}}}'
        read -r resp
        echo '{"type":"result","subtype":"success","is_error":false}'
        cat >/dev/null
        """#
        let events = Locked<[ClaudeStreamDriver.Event]>([])
        let driver = ClaudeStreamDriver(
            sessionID: UUID(), cwd: dir.path, logURL: log,
            executable: "/bin/sh", arguments: ["-c", script]
        ) { e in events.mutate { $0.append(e) } }
        try driver.start()

        try waitFor { driver.conversationID == "conv-1" }
        try driver.sendUser("make a.txt")
        try waitFor { !driver.pendingPermissions.isEmpty }
        #expect(driver.pendingPermissions.map(\.toolName) == ["Write"])

        try driver.respondPermission(requestID: "req-1", allow: true)
        try waitFor { events.value.contains(.turnEnded(isError: false)) }
        #expect(driver.pendingPermissions.isEmpty)
        #expect(throws: (any Error).self) { try driver.respondPermission(requestID: "req-1", allow: true) }

        driver.stop()
        try waitFor { events.value.contains { if case .exited = $0 { return true }; return false } }

        #expect(events.value.prefix(4) == [
            .conversationStarted(id: "conv-1"),
            .turnStarted,
            .permissionRequested(.init(requestID: "req-1", toolName: "Write", summary: "/w/a.txt",
                                       inputJSON: #"{"file_path":"\/w\/a.txt"}"#)),
            .turnStarted,
        ])
        let logText = try String(contentsOf: log, encoding: .utf8)
        #expect(logText.contains(#""behavior":"allow""#))
        #expect(logText.contains(#""updatedInput""#))
        #expect(!logText.contains("stream_event"))
        #expect(logText.contains(#""type":"result""#))
    }

    private func waitFor(_ cond: () -> Bool, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { throw WaitTimeout() }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private struct WaitTimeout: Error {}
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.withLock { _value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}
