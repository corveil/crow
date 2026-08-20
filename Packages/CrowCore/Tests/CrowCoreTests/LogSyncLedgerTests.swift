import Foundation
import Testing
import CrowCore

@Suite struct LogSyncLedgerTests {
    @Test func keyFormat() {
        #expect(LogSyncLedger.key(sessionUID: "SID", harness: .claude, kind: .sessionTranscript)
            == "SID:claude:session_transcript")
    }

    @Test func shouldUploadUnknownKey() {
        let ledger = LogSyncLedger()
        #expect(ledger.shouldUpload(key: "x", now: 100, retryBackoff: 60))
    }

    @Test func uploadedAndPermanentAreNeverRetried() {
        var ledger = LogSyncLedger()
        ledger.record(key: "u", entry: .init(status: .uploaded, sha256: "a", sizeBytes: 1, at: 0))
        ledger.record(key: "p", entry: .init(status: .skippedPermanent, sha256: "b", sizeBytes: 1, at: 0))
        #expect(!ledger.shouldUpload(key: "u", now: 1_000_000, retryBackoff: 60))
        #expect(!ledger.shouldUpload(key: "p", now: 1_000_000, retryBackoff: 60))
    }

    @Test func transientRetriesOnlyAfterBackoff() {
        var ledger = LogSyncLedger()
        ledger.record(key: "t", entry: .init(status: .failedTransient, sha256: "c", sizeBytes: 1, at: 100))
        #expect(!ledger.shouldUpload(key: "t", now: 150, retryBackoff: 100)) // 50s < 100s
        #expect(ledger.shouldUpload(key: "t", now: 250, retryBackoff: 100))  // 150s >= 100s
    }

    @Test func pruneDropsOldEntries() {
        var ledger = LogSyncLedger()
        let now = 1_000_000.0
        ledger.record(key: "old", entry: .init(status: .uploaded, sha256: "a", sizeBytes: 1,
                                                at: now - 40 * 86_400))
        ledger.record(key: "new", entry: .init(status: .uploaded, sha256: "b", sizeBytes: 1,
                                                at: now - 1 * 86_400))
        ledger.prune(retentionDays: 30, now: now)
        #expect(ledger.entries["old"] == nil)
        #expect(ledger.entries["new"] != nil)
    }

    @Test func pruneWithZeroRetentionKeepsEverything() {
        var ledger = LogSyncLedger()
        ledger.record(key: "old", entry: .init(status: .uploaded, sha256: "a", sizeBytes: 1, at: 0))
        ledger.prune(retentionDays: 0, now: 1_000_000_000)
        #expect(ledger.entries["old"] != nil)
    }

    @Test func persistenceRoundTrip() throws {
        let devRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("logsync-ledger-\(UUID().uuidString)", isDirectory: true).path
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        var ledger = LogSyncLedger()
        ledger.record(key: "k", entry: .init(status: .uploaded, sha256: "sha", sizeBytes: 42, at: 7))
        try ledger.save(devRoot: devRoot)

        let loaded = LogSyncLedger.load(devRoot: devRoot)
        #expect(loaded == ledger)
        #expect(loaded.entries["k"]?.sizeBytes == 42)
    }

    @Test func loadMissingReturnsEmpty() {
        let devRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("logsync-ledger-missing-\(UUID().uuidString)", isDirectory: true).path
        #expect(LogSyncLedger.load(devRoot: devRoot).entries.isEmpty)
    }
}
