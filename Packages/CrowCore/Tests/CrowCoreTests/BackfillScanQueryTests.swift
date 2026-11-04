import Foundation
import Testing
@testable import CrowCore

// MARK: - Backfill scan filtering / paging (CROW-1378)

@Suite struct BackfillScanQueryTests {
    private func row(
        _ uid: String, harness: LogSyncHarness = .claude, workspace: String? = "Corveil",
        confidence: BackfillConfidence = .high, status: BackfillUploadStatus = .new,
        modifiedAt: Double = 0
    ) -> BackfillSession {
        BackfillSession(
            claudeSessionUID: uid, filePath: "/t/\(uid).jsonl", slug: "t", harness: harness,
            modifiedAt: modifiedAt, workspace: workspace, confidence: confidence, uploadStatus: status)
    }

    @Test func filterMatchesEachDimension() {
        let rows = [
            row("a", harness: .claude, workspace: "Corveil", confidence: .high, status: .new),
            row("b", harness: .codex, workspace: "corveil", confidence: .medium, status: .uploaded),
            row("c", harness: .cursor, workspace: nil, confidence: .low, status: .failed),
            row("d", harness: .claude, workspace: "Other", confidence: .high, status: .skipped),
        ]
        func uids(_ f: BackfillScanFilter) -> [String] { rows.filter(f.matches).map(\.claudeSessionUID) }

        #expect(uids(BackfillScanFilter()) == ["a", "b", "c", "d"])
        #expect(BackfillScanFilter().isEmpty)
        #expect(uids(BackfillScanFilter(workspace: "CORVEIL")) == ["a", "b"])
        #expect(uids(BackfillScanFilter(confidence: .high)) == ["a", "d"])
        #expect(uids(BackfillScanFilter(status: .uploaded)) == ["b"])
        #expect(uids(BackfillScanFilter(status: .notUploaded)) == ["a", "c", "d"])
        #expect(uids(BackfillScanFilter(harness: .claude)) == ["a", "d"])
        #expect(uids(BackfillScanFilter(workspace: "corveil", confidence: .high)) == ["a"])
    }

    @Test func orderIsNewestFirstThenHarnessThenUID() {
        let rows = [
            row("z", harness: .codex, modifiedAt: 5),
            row("b", harness: .claude, modifiedAt: 5),
            row("a", harness: .claude, modifiedAt: 5),
            row("new", modifiedAt: 9),
        ]
        let ordered = BackfillScanQuery.ordered(rows).map(\.claudeSessionUID)
        #expect(ordered == ["new", "a", "b", "z"])
        #expect(BackfillScanQuery.ordered(rows.reversed()).map(\.claudeSessionUID) == ordered)
    }

    @Test func breakdownCountsEveryDimension() {
        let b = BackfillScanBreakdown(sessions: [
            row("a", harness: .claude, workspace: "W", confidence: .high, status: .new),
            row("b", harness: .codex, workspace: nil, confidence: .low, status: .uploaded),
            row("c", harness: .claude, workspace: "W", confidence: .high, status: .uploaded),
        ])
        #expect(b.total == 3)
        #expect(b.byHarness == ["claude": 2, "codex": 1])
        #expect(b.byWorkspace == ["W": 2, BackfillScanBreakdown.noWorkspace: 1])
        #expect(b.byConfidence == ["high": 2, "low": 1])
        #expect(b.byUploadStatus == ["new": 1, "uploaded": 2])
    }

    @Test func pageRespectsLimitAndReportsNextOffset() {
        let rows = Array(0..<10)
        let p1 = BackfillScanQuery.page(rows, offset: 0, limit: 4, maxBytes: .max, size: { _ in 1 })
        #expect(p1.rows == [0, 1, 2, 3])
        #expect(p1.nextOffset == 4)
        #expect(!p1.truncatedByBytes)
        let last = BackfillScanQuery.page(rows, offset: 8, limit: 4, maxBytes: .max, size: { _ in 1 })
        #expect(last.rows == [8, 9])
        #expect(last.nextOffset == nil)
        let past = BackfillScanQuery.page(rows, offset: 50, limit: 4, maxBytes: .max, size: { _ in 1 })
        #expect(past.rows.isEmpty)
        #expect(past.nextOffset == nil)
    }

    @Test func pageStopsAtByteBudgetButAlwaysProgresses() {
        let rows = Array(0..<10)
        // Each row costs 10 + 1 bytes; a 35-byte budget fits three.
        let p = BackfillScanQuery.page(rows, offset: 0, limit: 100, maxBytes: 35, size: { _ in 10 })
        #expect(p.rows == [0, 1, 2])
        #expect(p.nextOffset == 3)
        #expect(p.truncatedByBytes)
        // A row bigger than the whole budget still pages, one at a time.
        let huge = BackfillScanQuery.page(rows, offset: 3, limit: 100, maxBytes: 5, size: { _ in 10 })
        #expect(huge.rows == [3])
        #expect(huge.nextOffset == 4)
    }

    @Test func walkingPagesReturnsEveryRowExactlyOnce() {
        let rows = Array(0..<1_003)
        var seen: [Int] = []
        var offset: Int? = 0
        while let o = offset {
            let p = BackfillScanQuery.page(rows, offset: o, limit: 100, maxBytes: 700, size: { _ in 9 })
            seen += p.rows
            offset = p.nextOffset
        }
        #expect(seen == rows)
    }
}
