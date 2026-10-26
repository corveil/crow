import Foundation
import Testing
@testable import CrowCore

/// Chat view transcript reader. Fixture lines are hand-written to the shapes Claude Code
/// 2.1.x and Codex 0.16x persist — never read from a live `~/.claude` (ADR 0012).
@Suite struct ChatTranscriptTests {
    static let claudeFixture = #"""
    {"type":"permission-mode","permissionMode":"auto"}
    {"type":"user","isSidechain":false,"timestamp":"T1","message":{"role":"user","content":"Fix the flaky test"}}
    {"type":"assistant","isSidechain":false,"timestamp":"T2","message":{"id":"m1","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"x"}]}}
    {"type":"assistant","isSidechain":false,"timestamp":"T3","message":{"id":"m1","role":"assistant","content":[{"type":"text","text":"Looking at it.\n"}]}}
    {"type":"assistant","isSidechain":false,"timestamp":"T4","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"swift test --filter Flaky","description":"run it"}}],"stop_reason":"tool_use"}}
    {"type":"user","isSidechain":false,"timestamp":"T5","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"FAIL: expected 1 got 2","is_error":true}]}}
    {"type":"assistant","isSidechain":true,"timestamp":"T6","message":{"role":"assistant","content":[{"type":"text","text":"subagent chatter"}]}}
    {"type":"user","isMeta":true,"timestamp":"T7","message":{"role":"user","content":"<system-reminder>meta</system-reminder>"}}
    {"type":"assistant","isSidechain":false,"timestamp":"T8","message":{"id":"m2","role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Read","input":{"file_path":"/a/b.swift"}}]}}
    {"type":"user","isSidechain":false,"timestamp":"T9","message":{"role":"user","content":[{"tool_use_id":"toolu_2","type":"tool_result","content":[{"type":"text","text":"line1"},{"type":"image","source":{}}]}]}}
    {"type":"assistant","isSidechain":false,"timestamp":"T10","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"Fixed."}],"stop_reason":"end_turn"}}
    {"type":"system","subtype":"turn_duration","durationMs":4200,"timestamp":"T11"}
    {"type":"user","isSidechain":false,"timestamp":"T12","message":{"role":"user","content":"<command-name>/compact</command-name>\n<command-message>compact</command-message>\n<command-args></command-args>"}}
    {"type":"user","isSidechain":false,"timestamp":"T13","message":{"role":"user","content":"<bash-input>ls</bash-input>"}}
    not json at all
    {"type":"system","subtype":"compact_boundary","timestamp":"T14"}
    """#

    @Test func claudeFixtureReducesToChatEvents() {
        let events = ChatTranscript.parse(Data(Self.claudeFixture.utf8), format: .claude)
        #expect(events.map(\.kind) == [
            .user, .assistant, .toolCall, .toolResult, .toolCall, .toolResult,
            .assistant, .turnEnd, .user, .user, .notice,
        ])
        #expect(events[0].text == "Fix the flaky test")
        #expect(events[1].text == "Looking at it.")
        #expect(events[2].toolName == "Bash")
        #expect(events[2].text == "swift test --filter Flaky")
        #expect(events[2].toolID == "toolu_1")
        #expect(events[3].toolID == "toolu_1")
        #expect(events[3].isError)
        #expect(events[4].text == "/a/b.swift")
        #expect(events[5].text == "line1\n[image]")
        #expect(events[7].durationMs == 4200)
        #expect(events[8].text == "/compact")
        #expect(events[9].text == "! ls")
        #expect(events[10].text == "Conversation compacted")
    }

    @Test func claudeUsageIsTheLatestMainCallsPromptTokens() {
        let lines = #"""
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":2,"cache_read_input_tokens":40000,"cache_creation_input_tokens":1000,"output_tokens":50}}}
        {"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":9,"cache_read_input_tokens":9}}}
        {"type":"assistant","message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":0}}}
        {"type":"assistant","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":4,"cache_read_input_tokens":41000,"cache_creation_input_tokens":600,"output_tokens":9}}}
        {"type":"user","message":{"content":"next"}}
        """#
        let (_, usage) = ChatTranscript.parseWithUsage(Data(lines.utf8), format: .claude)
        #expect(usage == ChatUsage(usedTokens: 41_604, model: "claude-opus-5-5"))
        #expect(ChatTranscript.parseWithUsage(Data(#"{"type":"user","message":{"content":"x"}}"#.utf8), format: .claude).usage == nil)
    }

    @Test func codexUsageCarriesItsOwnWindow() {
        let lines = #"""
        {"type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25559,"cached_input_tokens":2432,"output_tokens":13},"model_context_window":258400}}}
        """#
        let (_, usage) = ChatTranscript.parseWithUsage(Data(lines.utf8), format: .codex)
        #expect(usage == ChatUsage(usedTokens: 25_559, model: "gpt-5.5", maxTokens: 258_400))
    }

    @Test func contextWindowTable() {
        // Values observed in stream-json `result.modelUsage[*].contextWindow`.
        #expect(ChatContextWindow.maxTokens(model: "claude-opus-5-5") == 1_000_000)
        #expect(ChatContextWindow.maxTokens(model: "claude-haiku-5-5") == 1_000_000)
        #expect(ChatContextWindow.maxTokens(model: "claude-fable-5-1") == 1_000_000)
        #expect(ChatContextWindow.maxTokens(model: "claude-opus-4-1[1m]") == 1_000_000)
        #expect(ChatContextWindow.maxTokens(model: "claude-sonnet-4-5-20250929") == 200_000)
        #expect(ChatContextWindow.maxTokens(model: "claude-3-5-haiku-20241022") == 200_000)
        #expect(ChatContextWindow.maxTokens(model: "some-future-model") == nil)
        #expect(ChatContextWindow.maxTokens(model: nil) == nil)
    }

    @Test func toolResultsAreClipped() {
        let long = String(repeating: "x", count: ChatTranscript.maxToolResultChars + 50)
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"\#(long)"}]}}"#
        let events = ChatTranscript.parse(Data(line.utf8), format: .claude)
        #expect(events.count == 1)
        #expect(events[0].text.count == ChatTranscript.maxToolResultChars + 1) // + "…"
    }

    static let codexFixture = #"""
    {"timestamp":"C0","type":"session_meta","payload":{"id":"abc"}}
    {"timestamp":"C1","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"<permissions instructions>"}]}}
    {"timestamp":"C2","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\n<cwd>/x</cwd>"}]}}
    {"timestamp":"C3","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"list files"}]}}
    {"timestamp":"C3b","type":"event_msg","payload":{"type":"user_message","message":"list files"}}
    {"timestamp":"C4","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"zzz"}}
    {"timestamp":"C5","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"rg --files\",\"workdir\":\"/x\"}","call_id":"call_1"}}
    {"timestamp":"C6","type":"response_item","payload":{"type":"function_call_output","call_id":"call_1","output":"Chunk ID: f9adb6\nWall time: 0.3 seconds\nProcess exited with code 0\nOutput:\na.swift\nb.swift"}}
    {"timestamp":"C7","type":"response_item","payload":{"type":"custom_tool_call","call_id":"call_2","name":"apply_patch","input":"*** Begin Patch\n*** Add File: c.swift"}}
    {"timestamp":"C8","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call_2","output":"{\"output\":\"Success.\",\"metadata\":{}}"}}
    {"timestamp":"C9","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Two files."}]}}
    {"timestamp":"C10","type":"event_msg","payload":{"type":"task_complete","duration_ms":3761}}
    """#

    @Test func codexFixtureReducesToChatEvents() {
        let events = ChatTranscript.parse(Data(Self.codexFixture.utf8), format: .codex)
        #expect(events.map(\.kind) == [.user, .toolCall, .toolResult, .toolCall, .toolResult, .assistant, .turnEnd])
        #expect(events[0].text == "list files")
        #expect(events[1].toolName == "exec_command")
        #expect(events[1].text == "rg --files")
        #expect(events[2].toolID == "call_1")
        #expect(events[2].text == "a.swift\nb.swift")
        #expect(events[3].text == "*** Begin Patch")
        #expect(events[4].text == "Success.")
        #expect(events[6].durationMs == 3761)
    }

    @Test func readTailsByCursorAndHoldsBackPartialLine() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let first = #"{"type":"user","message":{"content":"one"}}"# + "\n"
        let partial = #"{"type":"user","message":{"content":"tw"#
        try Data((first + partial).utf8).write(to: file)

        let page1 = try ChatTranscript.read(path: file.path, format: .claude, cursor: nil)
        #expect(page1.events.map(\.text) == ["one"])
        #expect(page1.cursor == first.utf8.count)
        #expect(!page1.truncated)

        // The writer finishes the line and appends another.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"o"}}"# + "\n" + #"{"type":"user","message":{"content":"three"}}"# + "\n").utf8))
        try handle.close()

        let page2 = try ChatTranscript.read(path: file.path, format: .claude, cursor: page1.cursor)
        #expect(page2.events.map(\.text) == ["two", "three"])

        let page3 = try ChatTranscript.read(path: file.path, format: .claude, cursor: page2.cursor)
        #expect(page3.events.isEmpty)
        #expect(page3.cursor == page2.cursor)

        // A cursor past EOF (file replaced) restarts from the top.
        let page4 = try ChatTranscript.read(path: file.path, format: .claude, cursor: page2.cursor + 10_000)
        #expect(page4.events.map(\.text) == ["one", "two", "three"])

        // A negative cursor reads like no cursor (the tail) instead of trapping
        // (#1372 review). This file is smaller than the tail window.
        let page5 = try ChatTranscript.read(path: file.path, format: .claude, cursor: -1)
        #expect(page5.events.map(\.text) == ["one", "two", "three"])
        #expect(page5.cursor == page2.cursor)
        let page6 = try ChatTranscript.read(path: file.path, format: .claude, cursor: Int.min)
        #expect(page6.events.count == 3)
    }

    @Test func pagesAreCappedAndCatchUpOverSeveralReads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let line = { (n: Int) in #"{"type":"user","message":{"content":"m\#(n)"}}"# + "\n" }
        let lines = (0..<10).map(line)
        let giant = #"{"type":"user","message":{"content":""# + String(repeating: "x", count: 300) + "\"}}\n"
        try Data((lines.joined() + giant + line(10)).utf8).write(to: file)

        // From 0 with a small page cap: each read stops at the last whole line.
        var cursor = 0
        var texts: [String] = []
        for _ in 0..<20 {
            let page = try ChatTranscript.read(path: file.path, format: .claude, cursor: cursor, maxPageBytes: 120)
            texts += page.events.map(\.text)
            if page.cursor == cursor { break }
            cursor = page.cursor
        }
        // The line longer than a page is skipped, not a stall; the rest arrives.
        #expect(texts == (0...10).map { "m\($0)" })
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! Int
        #expect(cursor == size)
    }

    @Test func toolInputSummaryFallsBackToCompactJSON() {
        let s = ChatTranscript.toolInputSummary(name: "Custom", input: ["b": 1, "a": "x"])
        #expect(s == #"{"a":"x","b":1}"#)
    }
}
