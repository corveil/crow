import CrowCore
import CrowIPC
import Foundation
import Testing
@testable import CrowEngine

/// `find-session` and `agent_conversations` (CROW-1476).
@Suite struct AgentConversationRPCTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ name: String, kind: SessionKind = .work, conversations: [String]) -> Session {
        var s = Session(name: name, kind: kind)
        for (i, id) in conversations.enumerated() {
            s.recordHarnessConversationID(id, at: t0.addingTimeInterval(Double(i) * 600))
        }
        return s
    }

    private var sessions: [Session] {
        [
            session("alpha", conversations: ["7f3a9c10-aaaa-4bbb-8ccc-000000000001", "7f3a9c10-aaaa-4bbb-8ccc-000000000002"]),
            session("beta", conversations: ["0b1e2d3c-1111-4222-8333-444455556666"]),
            session("Manager 2", kind: .manager, conversations: ["abcd1234"]),
        ]
    }

    @Test func aFullIDFindsItsSession() throws {
        let result = try AgentConversationRPC.findSession(
            agentSession: "0b1e2d3c-1111-4222-8333-444455556666", in: sessions)
        #expect(result["name"] == .string("beta"))
        #expect(result["kind"] == .string("work"))
        guard case .object(let conversation) = result["conversation"] else {
            Issue.record("no conversation object"); return
        }
        #expect(conversation["id"] == .string("0b1e2d3c-1111-4222-8333-444455556666"))
        #expect(conversation["agent_kind"] == .string("claude-code"))
        #expect(conversation["started_at"] == .string(ISO8601DateFormatter().string(from: t0)))
    }

    @Test func aUniquePrefixMatchesCaseInsensitively() throws {
        let result = try AgentConversationRPC.findSession(agentSession: "0B1E2D", in: sessions)
        #expect(result["name"] == .string("beta"))
        let manager = try AgentConversationRPC.findSession(agentSession: "abcd", in: sessions)
        #expect(manager["kind"] == .string("manager"))
    }

    @Test func aTranscriptPathIsReducedToItsID() throws {
        let path = "/Users/x/.claude/projects/-Users-x-dev-repo/0b1e2d3c-1111-4222-8333-444455556666.jsonl"
        let result = try AgentConversationRPC.findSession(agentSession: path, in: sessions)
        #expect(result["name"] == .string("beta"))
    }

    @Test func anAmbiguousPrefixListsTheCandidates() {
        #expect(AgentConversationRPC.find(conversation: "7f3a9c10", in: sessions).isAmbiguous(count: 2))
        do {
            _ = try AgentConversationRPC.findSession(agentSession: "7f3a9c10", in: sessions)
            Issue.record("expected an ambiguity error")
        } catch let error as RPCError {
            guard case .applicationError(let message) = error else { Issue.record("\(error)"); return }
            #expect(message.contains("matches 2 conversations"))
            #expect(message.contains("session alpha"))
        } catch { Issue.record("\(error)") }
    }

    @Test func anExactIDWinsOverLongerIDsItPrefixes() {
        let s = [session("short", conversations: ["abcd1"]), session("long", conversations: ["abcd12"])]
        guard case .found(let match) = AgentConversationRPC.find(conversation: "ABCD1", in: s) else {
            Issue.record("expected a match"); return
        }
        #expect(match.session.name == "short")
    }

    @Test func noMatchAndBadQueriesThrow() {
        #expect(throws: RPCError.self) { try AgentConversationRPC.findSession(agentSession: "ffffffff", in: sessions) }
        #expect(throws: RPCError.self) { try AgentConversationRPC.findSession(agentSession: "abc", in: sessions) }
        #expect(throws: RPCError.self) { try AgentConversationRPC.findSession(agentSession: "  ", in: sessions) }
        #expect(throws: RPCError.self) { try AgentConversationRPC.findSession(agentSession: nil, in: sessions) }
        #expect(throws: RPCError.self) { try AgentConversationRPC.findSession(agentSession: "abcd\n12", in: sessions) }
    }

    @Test func aCurrentIDTheHistoryPredatesIsStillFound() throws {
        var legacy = Session(name: "legacy", kind: .work)
        legacy.harnessConversationID = "99999999-legacy"
        let result = try AgentConversationRPC.findSession(agentSession: "99999999", in: [legacy])
        #expect(result["name"] == .string("legacy"))
        guard case .object(let conversation) = result["conversation"] else {
            Issue.record("no conversation object"); return
        }
        #expect(conversation["started_at"] == .null)
        #expect(conversation["last_active_at"] == .null)
    }

    @Test func conversationsJSONListsEveryConversationOldestFirst() {
        guard case .array(let rows) = AgentConversationRPC.conversationsJSON(sessions[0]) else {
            Issue.record("not an array"); return
        }
        let ids = rows.compactMap { row -> String? in
            guard case .object(let o) = row, case .string(let id) = o["id"] else { return nil }
            return id
        }
        #expect(ids == ["7f3a9c10-aaaa-4bbb-8ccc-000000000001", "7f3a9c10-aaaa-4bbb-8ccc-000000000002"])
        #expect(AgentConversationRPC.conversationsJSON(Session(name: "fresh")) == .array([]))
    }
}

private extension AgentConversationRPC.Outcome {
    func isAmbiguous(count: Int) -> Bool {
        if case .ambiguous(let matches) = self { return matches.count == count }
        return false
    }
}
