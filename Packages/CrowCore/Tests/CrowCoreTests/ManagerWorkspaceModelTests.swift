import Foundation
import Testing
@testable import CrowCore

/// CROW-1382: the workspace tag an extra Manager carries, the conversation
/// history its transcripts ship from, the default tag in config, and the
/// backfill rows that may no longer ship under an arbitrary workspace.
@Suite("Manager workspace tag (model)")
struct ManagerWorkspaceModelTests {

    // MARK: - Session.workspaceID / managerWorkspaceTag

    @Test func extraManagerTagIsInForce() {
        let ws = UUID()
        let session = Session(name: "Manager 2", kind: .manager, workspaceID: ws)
        #expect(session.managerWorkspaceTag == ws)
    }

    /// The primary Manager can never be tagged, so even a hand-edited store
    /// cannot route it through a workspace gateway.
    @Test func primaryManagerTagIsIgnored() {
        let session = Session(
            id: AppState.managerSessionID, name: "Manager", kind: .manager, workspaceID: UUID())
        #expect(session.managerWorkspaceTag == nil)
    }

    @Test func workSessionTagIsIgnored() {
        #expect(Session(name: "w", kind: .work, workspaceID: UUID()).managerWorkspaceTag == nil)
    }

    @Test func legacySessionDecodesUntaggedWithNoHistory() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Manager 2","status":"active","kind":"manager",
         "createdAt":0,"updatedAt":0}
        """
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.workspaceID == nil)
        #expect(session.harnessConversationHistory.isEmpty)
    }

    @Test func tagAndHistoryRoundTrip() throws {
        var session = Session(name: "Manager 2", kind: .manager, workspaceID: UUID())
        session.recordHarnessConversationID("conv-a")
        let decoded = try JSONDecoder().decode(
            Session.self, from: try JSONEncoder().encode(session))
        #expect(decoded.workspaceID == session.workspaceID)
        #expect(decoded.harnessConversationHistory == session.harnessConversationHistory)
    }

    // MARK: - harnessConversationHistory

    /// A `/clear` replaces `harnessConversationID`; the history keeps the
    /// conversation it replaced so log sync can still ship it.
    @Test func managerRecordsEveryConversationOnce() {
        var session = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        let first = session.recordHarnessConversationID("conv-a")
        let second = session.recordHarnessConversationID("conv-b")
        let repeated = session.recordHarnessConversationID("conv-b")
        // Back to an earlier id (a resume) moves the current id, not the history.
        let resumed = session.recordHarnessConversationID("conv-a")
        #expect(first && second && !repeated && resumed)
        #expect(session.harnessConversationID == "conv-a")
        #expect(session.harnessConversationHistory.map(\.id) == ["conv-a", "conv-b"])
    }

    /// A handoff changes the agent; earlier conversations keep the harness
    /// that wrote them.
    @Test func historyKeepsEachConversationsHarness() {
        var session = Session(name: "Manager 2", kind: .manager, agentKind: .claudeCode)
        session.recordHarnessConversationID("claude-1")
        session.applyAgentKind(.codex)
        session.recordHarnessConversationID("codex-1")
        #expect(session.harnessConversationHistory == [
            HarnessConversationRef(agentKind: .claudeCode, id: "claude-1"),
            HarnessConversationRef(agentKind: .codex, id: "codex-1"),
        ])
    }

    @Test func historyIsCapped() {
        var session = Session(name: "Manager 2", kind: .manager)
        for i in 0..<(Session.conversationHistoryLimit + 5) {
            session.recordHarnessConversationID("conv-\(i)")
        }
        #expect(session.harnessConversationHistory.count == Session.conversationHistoryLimit)
        #expect(session.harnessConversationHistory.first?.id == "conv-5")
    }

    /// Work sessions upload per Crow session; they keep no history.
    @Test func workSessionKeepsNoHistory() {
        var session = Session(name: "w", kind: .work)
        session.recordHarnessConversationID("conv-a")
        session.recordHarnessConversationID("conv-b")
        #expect(session.harnessConversationHistory.isEmpty)
    }

    // MARK: - ConfigDefaults.managerWorkspace

    @Test func defaultsDecodeManagerWorkspaceAndDefaultToNil() throws {
        let absent = try JSONDecoder().decode(ConfigDefaults.self, from: Data("{}".utf8))
        #expect(absent.managerWorkspace == nil)
        let set = try JSONDecoder().decode(
            ConfigDefaults.self, from: Data(#"{"managerWorkspace":"Corveil"}"#.utf8))
        #expect(set.managerWorkspace == "Corveil")
        let roundTrip = try JSONDecoder().decode(
            ConfigDefaults.self, from: try JSONEncoder().encode(set))
        #expect(roundTrip == set)
    }

    // MARK: - BackfillUploadGuard

    private func row(workspace: String?, confidence: BackfillConfidence) -> BackfillSession {
        BackfillSession(
            claudeSessionUID: "uid", filePath: "/x.jsonl", slug: "s",
            workspace: workspace, confidence: confidence)
    }

    @Test func managerTranscriptIsRefusedUnlessAllowed() {
        let manager = row(workspace: ".crow", confidence: .low)
        #expect(BackfillUploadGuard.refusalReason(
            for: manager, allowOrphans: true, allowManagerTranscripts: false)?
            .hasPrefix("manager_transcript") == true)
        #expect(BackfillUploadGuard.refusalReason(
            for: manager, allowOrphans: false, allowManagerTranscripts: true) == nil)
    }

    @Test func orphanIsRefusedUnlessAllowed() {
        let orphan = row(workspace: nil, confidence: .low)
        #expect(BackfillUploadGuard.refusalReason(
            for: orphan, allowOrphans: false, allowManagerTranscripts: true)?
            .hasPrefix("orphan") == true)
        #expect(BackfillUploadGuard.refusalReason(
            for: orphan, allowOrphans: true, allowManagerTranscripts: false) == nil)
    }

    @Test func attributedRowsAlwaysPass() {
        for confidence in [BackfillConfidence.high, .medium] {
            #expect(BackfillUploadGuard.refusalReason(
                for: row(workspace: "Corveil", confidence: confidence),
                allowOrphans: false, allowManagerTranscripts: false) == nil)
        }
    }
}
