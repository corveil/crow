import Foundation
import Testing
@testable import CrowCore

@Suite("TodoItem (CROW-1231)")
struct TodoItemTests {
    @Test func defaultsToCapturedWithEmptyTrail() {
        let item = TodoItem(text: "try a scratch list")
        #expect(item.state == .captured)
        #expect(item.note.isEmpty)
        #expect(item.tags.isEmpty)
        #expect(item.links.isEmpty)
        #expect(item.priority == nil)
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let json = #"{"text":"half-written"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TodoItem.self, from: Data(json.utf8))
        #expect(decoded.text == "half-written")
        #expect(decoded.state == .captured)
        #expect(decoded.note.isEmpty)
        #expect(decoded.tags.isEmpty)
        #expect(decoded.links.isEmpty)
    }

    @Test func normalizePriorityAcceptsP1ThroughP4() throws {
        #expect(try TodoItem.normalizePriority("P1") == "p1")
        #expect(try TodoItem.normalizePriority(" p4 ") == "p4")
        #expect(try TodoItem.normalizePriority("") == nil)
        #expect(try TodoItem.normalizePriority(nil) == nil)
        #expect(throws: TodoItem.NormalizeError.self) {
            _ = try TodoItem.normalizePriority("urgent")
        }
    }

    @Test func normalizeTagsTrimsAndUniquifies() {
        #expect(TodoItem.normalizeTags(["  ios ", "iOS", "", "cli"]) == ["ios", "cli"])
    }

    @Test func linkedSessionAndTicketPreferTheMostRecent() {
        let sessionA = UUID()
        let sessionB = UUID()
        var item = TodoItem(text: "x")
        item.links = [
            TodoLink(type: .session, sessionID: sessionA, label: "first"),
            TodoLink(type: .ticket, url: "https://github.com/o/r/issues/1", label: "#1"),
            TodoLink(type: .session, sessionID: sessionB, label: "second"),
        ]
        #expect(item.linkedSessionID == sessionB)
        #expect(item.linkedTicketURL == "https://github.com/o/r/issues/1")
    }

    @Test func roundTripPreservesTrail() throws {
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        let item = TodoItem(
            text: "native scratch list",
            note: "before a ticket exists",
            tags: ["crow"],
            priority: "p2",
            state: .exploring,
            links: [TodoLink(type: .session, sessionID: UUID(), label: "explore")],
            createdAt: created,
            updatedAt: created
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TodoItem.self, from: data)
        #expect(decoded == item)
    }
}
