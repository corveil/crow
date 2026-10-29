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

    /// The delete timeout's `failedTransient` may lose a race with the real
    /// upload; it must never reopen a settled slot (CROW-1394).
    @Test func recordUnlessSettledKeepsSettledOutcomes() async throws {
        let store = LogSyncLedgerStore(devRoot: try tempDevRoot())
        let failed = LogSyncLedger.Entry(
            status: .failedTransient, sha256: "", sizeBytes: 0, at: 9, reason: "delete_timeout")
        func key(_ uid: String) -> String {
            LogSyncLedger.key(sessionUID: uid, harness: .claude, kind: .sessionTranscript)
        }

        await store.record(key: key("up"), entry: .init(status: .uploaded, sha256: "s", sizeBytes: 1, at: 1))
        await store.record(key: key("perm"), entry: .init(status: .skippedPermanent, sha256: "s", sizeBytes: 1, at: 1))
        await store.record(key: key("retry"), entry: .init(status: .failedTransient, sha256: "s", sizeBytes: 1, at: 1))

        #expect(await store.recordUnlessSettled(key: key("up"), entry: failed) == false)
        #expect(await store.recordUnlessSettled(key: key("perm"), entry: failed) == false)
        #expect(await store.recordUnlessSettled(key: key("retry"), entry: failed))
        #expect(await store.recordUnlessSettled(key: key("new"), entry: failed))

        let snap = await store.snapshot()
        #expect(snap.entries[key("up")]?.status == .uploaded)
        #expect(snap.entries[key("perm")]?.status == .skippedPermanent)
        #expect(snap.entries[key("retry")]?.reason == "delete_timeout")
        #expect(snap.entries[key("new")]?.reason == "delete_timeout")
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
