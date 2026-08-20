import Foundation
import Testing
@testable import CrowCore

@Suite struct LogSyncLedgerStoreTests {
    private func tempDevRoot() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    @Test func recordsAndSnapshotsThroughDisk() async throws {
        let devRoot = try tempDevRoot()
        let store = LogSyncLedgerStore(devRoot: devRoot)
        let key = LogSyncLedger.key(sessionUID: "abc", harness: .claude, kind: .sessionTranscript)

        #expect(await store.shouldUpload(key: key, now: 0, retryBackoff: 0))
        await store.record(key: key, entry: .init(status: .uploaded, sha256: "s", sizeBytes: 10, at: 1))
        #expect(await store.shouldUpload(key: key, now: 0, retryBackoff: 0) == false)

        // Persisted to disk — a fresh load sees it.
        let onDisk = LogSyncLedger.load(devRoot: devRoot)
        #expect(onDisk.entries[key]?.status == .uploaded)
    }

    @Test func concurrentRecordsLoseNoUpdates() async throws {
        let devRoot = try tempDevRoot()
        let store = LogSyncLedgerStore(devRoot: devRoot)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let key = LogSyncLedger.key(
                        sessionUID: "s\(i)", harness: .claude, kind: .sessionTranscript)
                    await store.record(key: key, entry: .init(
                        status: .uploaded, sha256: "s", sizeBytes: i, at: Double(i)))
                }
            }
        }
        let snap = await store.snapshot()
        #expect(snap.entries.count == 50)
        // And the final persisted file has all 50 (no lost writes).
        #expect(LogSyncLedger.load(devRoot: devRoot).entries.count == 50)
    }

    @Test func sharedReturnsSameInstancePerDevRoot() async throws {
        let devRoot = try tempDevRoot()
        let a = LogSyncLedgerStore.shared(devRoot: devRoot)
        let b = LogSyncLedgerStore.shared(devRoot: devRoot)
        #expect(a === b)
    }
}
