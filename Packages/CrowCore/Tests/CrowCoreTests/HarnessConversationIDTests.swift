import Foundation
import Testing
@testable import CrowCore

@Suite("HarnessConversationID")
struct HarnessConversationIDTests {
    private let crow = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    @Test func prefersChatIdOverGenericSessionId() {
        let id = HarnessConversationID.extract(fields: [
            "session_id": crow.uuidString,
            "chatId": "chat-abc",
        ], crowSessionID: crow)
        #expect(id == "chat-abc")
    }

    @Test func rejectsCrowSessionUUID() {
        #expect(HarnessConversationID.extract(
            fields: ["session_id": crow.uuidString], crowSessionID: crow) == nil)
        #expect(HarnessConversationID.extract(
            fields: ["session_id": crow.uuidString.lowercased()], crowSessionID: crow) == nil)
    }

    @Test func readsClaudeTranscriptBasename() {
        let claude = "dfb5e99e-3195-4342-89fd-4025f1b7f09e"
        let id = HarnessConversationID.extract(fields: [
            "transcript_path": "/Users/x/.claude/projects/slug/\(claude).jsonl",
        ], crowSessionID: crow)
        #expect(id == claude)
    }

    @Test func readsConversationIdAndThreadId() {
        #expect(HarnessConversationID.extract(
            fields: ["conversationId": "CONV-1"], crowSessionID: crow) == "CONV-1")
        #expect(HarnessConversationID.extract(
            fields: ["thread_id": "thread-9"], crowSessionID: crow) == "thread-9")
    }

    @Test func rejectsEmptyAndControlCharacters() {
        #expect(HarnessConversationID.sanitize("  ") == nil)
        #expect(HarnessConversationID.sanitize("ab\ncd") == nil)
        #expect(HarnessConversationID.sanitize("ok-id") == "ok-id")
    }
}
