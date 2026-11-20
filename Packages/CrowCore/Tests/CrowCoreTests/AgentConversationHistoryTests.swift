import Foundation
import Testing
@testable import CrowCore

/// `Session.harnessConversationHistory` stamps (CROW-1476): when each agent
/// conversation was first and last seen, for `agent_conversations` and
/// `crow find-session`.
@Suite struct AgentConversationHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aNewConversationIsStampedWhenFirstSeen() {
        var session = Session(name: "w", kind: .work, agentKind: .claudeCode)
        let r1 = session.recordHarnessConversationID("conv-a", at: t0)
        #expect(r1)
        let ref = session.harnessConversationHistory.first
        #expect(ref?.id == "conv-a")
        #expect(ref?.agentKind == .claudeCode)
        #expect(ref?.startedAt == t0)
        #expect(ref?.lastActiveAt == t0)
    }

    @Test func activityMovesForwardOnlyOncePerResolution() {
        var session = Session(name: "w", kind: .work)
        session.recordHarnessConversationID("conv-a", at: t0)
        // Within the resolution: no store write.
        let r2 = session.recordHarnessConversationID("conv-a", at: t0.addingTimeInterval(30))
        #expect(!r2)
        #expect(session.harnessConversationHistory[0].lastActiveAt == t0)
        // Past it: stamped, and the start never moves.
        let later = t0.addingTimeInterval(Session.conversationActivityResolution + 1)
        let r3 = session.recordHarnessConversationID("conv-a", at: later)
        #expect(r3)
        #expect(session.harnessConversationHistory[0].lastActiveAt == later)
        #expect(session.harnessConversationHistory[0].startedAt == t0)
    }

    @Test func resumingAnEarlierConversationStampsThatOne() {
        var session = Session(name: "w", kind: .work)
        session.recordHarnessConversationID("conv-a", at: t0)
        session.recordHarnessConversationID("conv-b", at: t0.addingTimeInterval(10))
        let resumed = t0.addingTimeInterval(600)
        let r4 = session.recordHarnessConversationID("conv-a", at: resumed)
        #expect(r4)
        #expect(session.harnessConversationID == "conv-a")
        #expect(session.harnessConversationHistory.map(\.id) == ["conv-a", "conv-b"])
        #expect(session.harnessConversationHistory[0].lastActiveAt == resumed)
        #expect(session.harnessConversationHistory[0].startedAt == t0)
    }

    /// An entry written before CROW-1476 has no stamps. Its start stays
    /// unknown; the next hook fills in activity once, not on every hook.
    @Test func aLegacyEntryGetsActivityButNoStart() throws {
        let id = UUID()
        let json = """
            {"id":"\(id.uuidString)","name":"Manager 2","status":"active","kind":"manager",
             "createdAt":0,"updatedAt":0,"harnessConversationID":"conv-a",
             "harnessConversationHistory":[{"agentKind":"claude-code","id":"conv-a"}]}
            """
        var session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.harnessConversationHistory[0].startedAt == nil)
        #expect(session.harnessConversationHistory[0].lastActiveAt == nil)
        let r5 = session.recordHarnessConversationID("conv-a", at: t0)
        #expect(r5)
        #expect(session.harnessConversationHistory[0].startedAt == nil)
        #expect(session.harnessConversationHistory[0].lastActiveAt == t0)
        let r6 = session.recordHarnessConversationID("conv-a", at: t0.addingTimeInterval(5))
        #expect(!r6)
    }

    @Test func stampsRoundTripAndDoNotAffectIdentity() throws {
        var session = Session(name: "w", kind: .work)
        session.recordHarnessConversationID("conv-a", at: t0)
        let decoded = try JSONDecoder().decode(Session.self, from: try JSONEncoder().encode(session))
        #expect(decoded.harnessConversationHistory[0].startedAt == t0)
        #expect(decoded.harnessConversationHistory[0].lastActiveAt == t0)
        // Equality and hashing are the kind and id only.
        let bare = HarnessConversationRef(agentKind: .claudeCode, id: "conv-a")
        #expect(decoded.harnessConversationHistory[0] == bare)
        #expect(Set([decoded.harnessConversationHistory[0], bare]).count == 1)
    }

    @Test func agentConversationsIncludesACurrentIDTheHistoryPredates() {
        var session = Session(name: "w", kind: .work)
        session.harnessConversationID = "conv-old"
        #expect(session.agentConversations == [HarnessConversationRef(agentKind: .claudeCode, id: "conv-old")])
        session.recordHarnessConversationID("conv-new", at: t0)
        #expect(session.agentConversations.map(\.id) == ["conv-new"])
    }
}
