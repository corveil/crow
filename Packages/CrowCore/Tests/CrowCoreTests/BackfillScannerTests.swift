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
