import Foundation

/// The single in-process owner of the upload ledger (CROW-1075).
///
/// The live collector used to `load` the ledger fresh, mutate it across a whole
/// sweep, and `save` at the end — safe only because it was the *sole* writer
/// (`LogSyncLedger` says as much). Backfill (CROW-1075) is a second, concurrent
/// writer: a user-initiated `backfill-upload` can run while the 5-minute poll
/// tick is mid-sweep. Two independent load→mutate→save cycles would lose
/// updates. This actor removes that hazard by keeping the ledger in memory and
/// serializing every read-modify-write; both the collector and the backfill
/// handler go through the one instance for a given dev root.
///
/// Persistence is write-through (each `record`/`prune` saves), and the value
/// type `LogSyncLedger` keeps all the pure logic — this actor only owns
/// concurrency and disk I/O.
public actor LogSyncLedgerStore {
    private let devRoot: String
    private var ledger: LogSyncLedger
    private var loaded = false

    public init(devRoot: String) {
        self.devRoot = devRoot
        self.ledger = LogSyncLedger()
    }

    /// Lazily load the on-disk ledger the first time it's touched, so
    /// constructing the store is cheap and a test can pre-seed the file.
    private func ensureLoaded() {
        guard !loaded else { return }
        ledger = LogSyncLedger.load(devRoot: devRoot)
        loaded = true
    }

    /// Whether this artifact slot should be uploaded now (delegates to the value
    /// type's policy).
    public func shouldUpload(key: String, now: Double, retryBackoff: Double) -> Bool {
        ensureLoaded()
        return ledger.shouldUpload(key: key, now: now, retryBackoff: retryBackoff)
    }

    /// Record an outcome and persist. Best-effort — a write failure is swallowed
    /// (the worst case is a duplicate upload the server 409s), matching the
    /// collector's existing tolerance.
    public func record(key: String, entry: LogSyncLedger.Entry) {
        ensureLoaded()
        ledger.record(key: key, entry: entry)
        persist()
    }

    /// Prune aged entries and persist.
    public func prune(retentionDays: Int, now: Double) {
        ensureLoaded()
        ledger.prune(retentionDays: retentionDays, now: now)
        persist()
    }

    /// A snapshot of the current ledger, for reconciling scan status.
    public func snapshot() -> LogSyncLedger {
        ensureLoaded()
        return ledger
    }

    private func persist() {
        do { try ledger.save(devRoot: devRoot) }
        catch { CrowLog.info("[LogSync] failed to persist log-sync ledger: \(error.localizedDescription)") }
    }

    // MARK: - Per-dev-root sharing

    private static let lock = NSLock()
    private nonisolated(unsafe) static var instances: [String: LogSyncLedgerStore] = [:]

    /// The one store for a dev root, created on first use. The collector poll
    /// loop and the backfill RPC handler both resolve their store this way, so a
    /// single actor mediates every ledger write in the process.
    public static func shared(devRoot: String) -> LogSyncLedgerStore {
        let key = (devRoot as NSString).standardizingPath
        lock.lock()
        defer { lock.unlock() }
        if let existing = instances[key] { return existing }
        let store = LogSyncLedgerStore(devRoot: key)
        instances[key] = store
        return store
    }
}
