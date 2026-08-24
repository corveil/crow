import Foundation
import Testing
@testable import CrowCore

@Suite struct BackfillScannerTests {
    /// Build a temp dev root + a temp Claude projects dir, returning both paths.
    private func makeTree() throws -> (devRoot: String, projects: URL, cleanup: () -> Void) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("backfill-scan-\(UUID().uuidString)", isDirectory: true)
        let devRoot = base.appendingPathComponent("Dev2", isDirectory: true)
        let projects = base.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: devRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        return (devRoot.path, projects, { try? FileManager.default.removeItem(at: base) })
    }

    private func writeTranscript(
        in projects: URL, slug: String, uid: String, cwd: String, branch: String
    ) throws {
        let dir = projects.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
        {"type":"mode","sessionId":"\(uid)"}
        {"type":"user","sessionId":"\(uid)","cwd":"\(cwd)","gitBranch":"\(branch)","timestamp":"2026-08-19T00:00:00Z"}
        """
        try body.write(to: dir.appendingPathComponent("\(uid).jsonl"), atomically: true, encoding: .utf8)
    }

    /// Write a Codex rollout — a first-line `session_meta` with cwd/id nested
    /// under `payload`, in the `<YYYY>/<MM>/<DD>` date tree Codex uses.
    private func writeCodexRollout(
        in codexSessions: URL, uid: String, cwd: String
    ) throws {
        let dir = codexSessions.appendingPathComponent("2026/08/19", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = """
        {"timestamp":"2026-08-19T00:00:00Z","type":"session_meta","payload":{"id":"\(uid)","cwd":"\(cwd)","git":{}}}
        {"timestamp":"2026-08-19T00:00:01Z","type":"event_msg","payload":{"type":"task_started"}}
        """
        try body.write(
            to: dir.appendingPathComponent("rollout-2026-08-19T00-00-00-\(uid).jsonl"),
            atomically: true, encoding: .utf8)
    }

    /// Write a Grok transcript — `<enc-cwd>/<session-uuid>/chat_history.jsonl`,
    /// where the directory name is the URL-encoded cwd — plus sibling files that
    /// must be ignored.
    private func writeGrokTranscript(
        in grokSessions: URL, uid: String, cwd: String
    ) throws {
        let sessionDir = grokSessions
            .appendingPathComponent(GrokSessionDir.encode(cwd), isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let body = """
        {"role":"system","content":"You are Grok"}
        {"role":"user","content":"hi"}
        """
        try body.write(
            to: sessionDir.appendingPathComponent("chat_history.jsonl"),
            atomically: true, encoding: .utf8)
        // Siblings the scanner must NOT pick up.
        try "{}".write(to: sessionDir.appendingPathComponent("events.jsonl"),
                       atomically: true, encoding: .utf8)
        try "{}".write(to: sessionDir.appendingPathComponent("hunk_records.jsonl"),
                       atomically: true, encoding: .utf8)
        try "{}".write(
            to: grokSessions.appendingPathComponent(GrokSessionDir.encode(cwd), isDirectory: true)
                .appendingPathComponent("prompt_history.jsonl"),
            atomically: true, encoding: .utf8)
    }

    @Test func reconstructsHighConfidenceSession() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }

        // A live clone so the repo → owner/repo resolves.
        let clone = URL(fileURLWithPath: devRoot)
            .appendingPathComponent("RadiusMethod/crow", isDirectory: true)
        try FileManager.default.createDirectory(
            at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let cwd = "\(devRoot)/RadiusMethod/crow-1075-session-backfill"
        try writeTranscript(
            in: projects, slug: "slug1", uid: "UID-1", cwd: cwd,
            branch: "feature/crow-1075-session-backfill")

        let scanner = BackfillScanner(
            devRoot: devRoot, projectsDir: projects,
            gitRemote: { path in
                path.hasSuffix("/RadiusMethod/crow") ? "https://github.com/corveil/crow.git" : nil
            })

        let sessions = await scanner.scan(ledger: LogSyncLedger())
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.claudeSessionUID == "UID-1")
        #expect(s.workspace == "RadiusMethod")
        #expect(s.worktreeName == "crow-1075-session-backfill")
        #expect(s.repoName == "crow")
        #expect(s.ownerRepo == "corveil/crow")
        #expect(s.host == "github.com")
        #expect(s.ticketNumber == 1075)
        #expect(s.confidence == .high)
        #expect(s.uploadStatus == .new)
    }

    @Test func orphanSessionOutsideDevRootIsLowConfidence() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        try writeTranscript(
            in: projects, slug: "slug2", uid: "UID-2",
            cwd: "/Users/j/Downloads/scratch", branch: "main")

        let scanner = BackfillScanner(devRoot: devRoot, projectsDir: projects, gitRemote: { _ in nil })
        let sessions = await scanner.scan(ledger: LogSyncLedger())
        let s = try #require(sessions.first { $0.claudeSessionUID == "UID-2" })
        #expect(s.workspace == nil)
        #expect(s.repoName == nil)
        #expect(s.confidence == .low)
    }

    @Test func ledgerStatusIsReconciled() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        try writeTranscript(
            in: projects, slug: "slug3", uid: "UID-3",
            cwd: "\(devRoot)/RadiusMethod/crow-9-x", branch: "feature/crow-9-x")

        var ledger = LogSyncLedger()
        ledger.record(
            key: LogSyncLedger.key(sessionUID: "UID-3", harness: .claude, kind: .sessionTranscript),
            entry: .init(status: .uploaded, sha256: "s", sizeBytes: 1, at: 1))

        let scanner = BackfillScanner(devRoot: devRoot, projectsDir: projects, gitRemote: { _ in nil })
        let sessions = await scanner.scan(ledger: ledger)
        let s = try #require(sessions.first { $0.claudeSessionUID == "UID-3" })
        #expect(s.uploadStatus == .uploaded)
    }

    @Test func reconstructsCodexHighConfidenceSession() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        let codex = URL(fileURLWithPath: devRoot)
            .deletingLastPathComponent().appendingPathComponent("codex-sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codex) }

        // A live clone so the repo → owner/repo resolves.
        let clone = URL(fileURLWithPath: devRoot)
            .appendingPathComponent("RadiusMethod/crow", isDirectory: true)
        try FileManager.default.createDirectory(
            at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let cwd = "\(devRoot)/RadiusMethod/crow-1089-wire-harness-log-collector"
        try writeCodexRollout(in: codex, uid: "CODEX-UID-1", cwd: cwd)

        let scanner = BackfillScanner(
            devRoot: devRoot, projectsDir: projects, codexSessionsDir: codex,
            gitRemote: { path in
                path.hasSuffix("/RadiusMethod/crow") ? "https://github.com/corveil/crow.git" : nil
            })

        let sessions = await scanner.scan(ledger: LogSyncLedger())
        // Only the Codex rollout — the (empty) Claude projects dir contributes none.
        let s = try #require(sessions.first { $0.claudeSessionUID == "CODEX-UID-1" })
        #expect(s.harness == .codex)
        #expect(s.workspace == "RadiusMethod")
        #expect(s.worktreeName == "crow-1089-wire-harness-log-collector")
        #expect(s.repoName == "crow")
        #expect(s.ownerRepo == "corveil/crow")
        #expect(s.ticketNumber == 1089)
        #expect(s.confidence == .high)
    }

    @Test func codexLedgerStatusKeyedByCodexHarness() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        let codex = URL(fileURLWithPath: devRoot)
            .deletingLastPathComponent().appendingPathComponent("codex-sessions2", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: codex) }
        try writeCodexRollout(in: codex, uid: "CODEX-UID-2", cwd: "\(devRoot)/RadiusMethod/crow-9-x")

        // A Claude ledger entry for the SAME uid must NOT mark the Codex row
        // uploaded — the harness slot distinguishes them.
        var ledger = LogSyncLedger()
        ledger.record(
            key: LogSyncLedger.key(sessionUID: "CODEX-UID-2", harness: .claude, kind: .sessionTranscript),
            entry: .init(status: .uploaded, sha256: "s", sizeBytes: 1, at: 1))

        let scanner = BackfillScanner(
            devRoot: devRoot, projectsDir: projects, codexSessionsDir: codex, gitRemote: { _ in nil })
        let s = try #require(await scanner.scan(ledger: ledger).first { $0.claudeSessionUID == "CODEX-UID-2" })
        #expect(s.uploadStatus == .new) // the Claude-harness entry does not apply

        // Now record it under the CODEX harness — it reconciles.
        var ledger2 = LogSyncLedger()
        ledger2.record(
            key: LogSyncLedger.key(sessionUID: "CODEX-UID-2", harness: .codex, kind: .sessionTranscript),
            entry: .init(status: .uploaded, sha256: "s", sizeBytes: 1, at: 1))
        let s2 = try #require(await scanner.scan(ledger: ledger2).first { $0.claudeSessionUID == "CODEX-UID-2" })
        #expect(s2.uploadStatus == .uploaded)
    }

    // MARK: Grok harness (CROW-1098)

    @Test func reconstructsGrokHighConfidenceSession() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        let grok = URL(fileURLWithPath: devRoot)
            .deletingLastPathComponent().appendingPathComponent("grok-sessions", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: grok) }

        // A live clone so the repo → owner/repo resolves.
        let clone = URL(fileURLWithPath: devRoot)
            .appendingPathComponent("RadiusMethod/crow", isDirectory: true)
        try FileManager.default.createDirectory(
            at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let cwd = "\(devRoot)/RadiusMethod/crow-1098-wire-grok-logs"
        try writeGrokTranscript(in: grok, uid: "GROK-UID-1", cwd: cwd)

        let scanner = BackfillScanner(
            devRoot: devRoot, projectsDir: projects, grokSessionsDir: grok,
            gitRemote: { path in
                path.hasSuffix("/RadiusMethod/crow") ? "https://github.com/corveil/crow.git" : nil
            })

        let sessions = await scanner.scan(ledger: LogSyncLedger())
        // Only the one chat_history.jsonl — siblings and prompt_history are ignored.
        #expect(sessions.count == 1)
        let s = try #require(sessions.first { $0.claudeSessionUID == "GROK-UID-1" })
        #expect(s.harness == .grok)
        #expect(s.cwd == cwd) // recovered by decoding the directory name
        #expect(s.workspace == "RadiusMethod")
        #expect(s.worktreeName == "crow-1098-wire-grok-logs")
        #expect(s.repoName == "crow")
        #expect(s.ownerRepo == "corveil/crow")
        #expect(s.ticketNumber == 1098)
        #expect(s.confidence == .high)
    }

    @Test func grokLedgerStatusKeyedByGrokHarness() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        let grok = URL(fileURLWithPath: devRoot)
            .deletingLastPathComponent().appendingPathComponent("grok-sessions2", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: grok) }
        try writeGrokTranscript(in: grok, uid: "GROK-UID-2", cwd: "\(devRoot)/RadiusMethod/crow-9-x")

        // A Claude ledger entry for the SAME uid must NOT mark the Grok row
        // uploaded — the harness slot distinguishes them.
        var ledger = LogSyncLedger()
        ledger.record(
            key: LogSyncLedger.key(sessionUID: "GROK-UID-2", harness: .claude, kind: .sessionTranscript),
            entry: .init(status: .uploaded, sha256: "s", sizeBytes: 1, at: 1))

        let scanner = BackfillScanner(
            devRoot: devRoot, projectsDir: projects, grokSessionsDir: grok, gitRemote: { _ in nil })
        let s = try #require(await scanner.scan(ledger: ledger).first { $0.claudeSessionUID == "GROK-UID-2" })
        #expect(s.uploadStatus == .new) // the Claude-harness entry does not apply

        // Now record it under the GROK harness — it reconciles.
        var ledger2 = LogSyncLedger()
        ledger2.record(
            key: LogSyncLedger.key(sessionUID: "GROK-UID-2", harness: .grok, kind: .sessionTranscript),
            entry: .init(status: .uploaded, sha256: "s", sizeBytes: 1, at: 1))
        let s2 = try #require(await scanner.scan(ledger: ledger2).first { $0.claudeSessionUID == "GROK-UID-2" })
        #expect(s2.uploadStatus == .uploaded)
    }

    // MARK: Cursor harness (CROW-1095)

    @Test func reconstructsCursorHighConfidenceSession() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        let cursorChats = URL(fileURLWithPath: devRoot)
            .deletingLastPathComponent().appendingPathComponent("cursor-chats", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cursorChats) }

        // A live clone so the repo → owner/repo resolves.
        let clone = URL(fileURLWithPath: devRoot)
            .appendingPathComponent("RadiusMethod/crow", isDirectory: true)
        try FileManager.default.createDirectory(
            at: clone.appendingPathComponent(".git"), withIntermediateDirectories: true)

        // The cwd lives in the sibling meta.json; the uid is the `<subId>` dir.
        let cwd = "\(devRoot)/RadiusMethod/crow-1095-wire-cursor-logs"
        _ = try CursorStoreFixture.write(
            dir: cursorChats.appendingPathComponent("chatA/SUBID-1", isDirectory: true),
            agentID: "SUBID-1", cwd: cwd, messages: [#"{"role":"user","content":"hi"}"#])

        let scanner = BackfillScanner(
            devRoot: devRoot, projectsDir: projects, cursorChatsDir: cursorChats,
            gitRemote: { path in
                path.hasSuffix("/RadiusMethod/crow") ? "https://github.com/corveil/crow.git" : nil
            })

        let sessions = await scanner.scan(ledger: LogSyncLedger())
        // Only the Cursor chat — the (empty) Claude/Codex dirs contribute none.
        let s = try #require(sessions.first { $0.claudeSessionUID == "SUBID-1" })
        #expect(s.harness == .cursor)
        #expect(s.workspace == "RadiusMethod")
        #expect(s.worktreeName == "crow-1095-wire-cursor-logs")
        #expect(s.repoName == "crow")
        #expect(s.ownerRepo == "corveil/crow")
        #expect(s.ticketNumber == 1095)
        #expect(s.confidence == .high)
        // The scan is disk-only: the filePath points at the store.db, but cwd/uid
        // came from the dir name + meta.json, never from opening the database.
        #expect(s.filePath.hasSuffix("SUBID-1/store.db"))
    }

    @Test func cursorChatWithoutCwdIsDroppedToLowConfidence() async throws {
        let (devRoot, projects, cleanup) = try makeTree()
        defer { cleanup() }
        let cursorChats = URL(fileURLWithPath: devRoot)
            .deletingLastPathComponent().appendingPathComponent("cursor-chats-2", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cursorChats) }

        // No cwd in meta.json → unattributable → orphan (low), never misfiled.
        _ = try CursorStoreFixture.write(
            dir: cursorChats.appendingPathComponent("chatB/SUBID-2", isDirectory: true),
            agentID: "SUBID-2", cwd: nil, messages: [#"{"role":"user"}"#])

        let scanner = BackfillScanner(
            devRoot: devRoot, projectsDir: projects, cursorChatsDir: cursorChats, gitRemote: { _ in nil })
        let s = try #require(await scanner.scan(ledger: LogSyncLedger())
            .first { $0.claudeSessionUID == "SUBID-2" })
        #expect(s.harness == .cursor)
        #expect(s.cwd == nil)
        #expect(s.workspace == nil)
        #expect(s.confidence == .low)
    }

    @Test func summaryCountsByTier() {
        let sessions = [
            BackfillSession(claudeSessionUID: "a", filePath: "", slug: "", confidence: .high, uploadStatus: .uploaded),
            BackfillSession(claudeSessionUID: "b", filePath: "", slug: "", confidence: .high, uploadStatus: .new),
            BackfillSession(claudeSessionUID: "c", filePath: "", slug: "", confidence: .medium, uploadStatus: .new),
            BackfillSession(claudeSessionUID: "d", filePath: "", slug: "", confidence: .low, uploadStatus: .new),
        ]
        let sum = BackfillSummary(sessions: sessions)
        #expect(sum.total == 4)
        #expect(sum.uploaded == 1)
        #expect(sum.linkable == 2)
        #expect(sum.repoOnly == 1)
        #expect(sum.orphan == 1)
    }
}
