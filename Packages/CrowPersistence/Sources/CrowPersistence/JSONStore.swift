import Foundation
import CrowCore

/// Persisted data structure.
///
/// The pre-CROW-508 `issueTrackerState` blob (last-observed PR status +
/// emitted-transition dedup keys / meta) is no longer persisted: the
/// stateless "needs refine" rule derives the answer from the PR on every
/// poll, so cross-restart state isn't needed. Older `store.json` files may
/// still carry that key; JSON decoding silently ignores unknown keys, so
/// existing stores keep loading cleanly without a migration step.
public struct StoreData: Codable, Sendable {
    public var sessions: [Session]
    public var worktrees: [SessionWorktree]
    public var links: [SessionLink]
    public var terminals: [SessionTerminal]
    /// Color-driving hook state per session, keyed by session UUID string (#367).
    /// Optional so older `store.json` files lacking the key still decode — the
    /// synthesized `Codable` tolerates a missing optional, keeping us backward
    /// compatible and avoiding the corrupt-store backup path.
    public var hookStates: [String: PersistedHookState]?
    /// Durable analytics snapshot per ended session, keyed by session UUID
    /// string (#690, ADR 0008). Optional for the same backward-compat reason
    /// as `hookStates`. Entries deliberately outlive session deletion — the
    /// scorecard's trailing-4-week baseline must survive the retention reaper.
    public var analyticsSnapshots: [String: SessionAnalyticsSnapshot]?
    /// Durable PR→session attribution per PR, keyed by PR URL (#693,
    /// ADR 0008 follow-up 5). Optional for the same backward-compat reason
    /// as `hookStates`. Entries deliberately outlive session deletion —
    /// merged-PR-per-window counts must survive the retention reaper.
    public var prAttributions: [String: PRSessionAttribution]?

    public init(
        sessions: [Session] = [],
        worktrees: [SessionWorktree] = [],
        links: [SessionLink] = [],
        terminals: [SessionTerminal] = [],
        hookStates: [String: PersistedHookState]? = nil,
        analyticsSnapshots: [String: SessionAnalyticsSnapshot]? = nil,
        prAttributions: [String: PRSessionAttribution]? = nil
    ) {
        self.sessions = sessions
        self.worktrees = worktrees
        self.links = links
        self.terminals = terminals
        self.hookStates = hookStates
        self.analyticsSnapshots = analyticsSnapshots
        self.prAttributions = prAttributions
    }
}

/// Thread-safe JSON file store for session persistence.
///
/// Uses `NSLock` to serialize access to the in-memory `StoreData` and disk writes.
/// The `nonisolated(unsafe)` annotation on `_data` is safe because all reads and writes
/// go through the lock. An actor was not used because `mutate()` must be synchronous
/// to support callers on the MainActor without requiring `await`.
///
/// On initialization, if `store.json` is corrupt (fails to decode), the file is backed up
/// to `store.json.bak` and the store starts fresh with empty data.
///
/// Performs a one-time migration from the legacy "rm-ai-ide" application support directory
/// when no "crow" directory exists yet (via `AppSupportDirectory`).
public final class JSONStore: Sendable {
    private let fileURL: URL
    private let lock = NSLock()
    private nonisolated(unsafe) var _data: StoreData
    /// Monotonic mutation counter, bumped under `lock` for every `mutate`.
    /// Each snapshot carries the sequence it was taken at so the write path
    /// can drop stale snapshots (see `mutate`).
    private nonisolated(unsafe) var writeSeq: UInt64 = 0
    /// Serializes disk writes independently of `lock`, so the in-memory data
    /// lock is never held across the (potentially slow) encode + atomic write.
    private let writeLock = NSLock()
    /// Highest sequence already persisted, guarded by `writeLock`.
    private nonisolated(unsafe) var lastWrittenSeq: UInt64 = 0
    /// File signature (mtime + size) captured after our most recent authored
    /// write, or after `init`/`reload` adopted the on-disk file. Guarded by
    /// `writeLock`. The external-writer tripwire compares the live file against
    /// this before each `mutate` (and in `reload`): a mismatch means a *second*
    /// process wrote `store.json` under us — the single-writer violation that
    /// silently wipes sessions, since `mutate` rewrites the whole file (CROW-759).
    /// Diagnostic only; the daemon's store-writer flock is the enforcement.
    private nonisolated(unsafe) var lastKnownStat: StatSignature?

    /// mtime + size of `store.json` — a cheap change-detection signature for the
    /// external-writer tripwire (CROW-759).
    private struct StatSignature: Equatable {
        let mtime: TimeInterval
        let size: Int
    }

    public var data: StoreData {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }

    /// On-disk location of `store.json`. Exposed so a second process (the
    /// `crowd` daemon) can watch it for external writes and `reload()`
    /// (CROW-581).
    public var storeURL: URL { fileURL }

    /// Last-modification date of `store.json`, or nil if it doesn't exist yet.
    /// Cheap change-detection for a polling reloader.
    public var storeModificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    /// Re-read `store.json` from disk into the in-memory snapshot, discarding a
    /// stale cached copy. Used by the daemon to pick up writes made by the
    /// desktop app (the primary writer) without a restart. A missing or
    /// undecodable file leaves the current snapshot untouched.
    public func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(StoreData.self, from: data) else { return }
        // Tripwire (CROW-759): a reload that finds the file changed since our last
        // authored write is picking up a *second writer* — flag it before adopting.
        checkForExternalWrite(context: "reload")
        lock.lock()
        _data = decoded
        lock.unlock()
        // The file we just read is now our baseline; the next `mutate` compares
        // against it rather than re-flagging the same external write forever.
        writeLock.lock()
        lastKnownStat = Self.statSignature(fileURL)
        writeLock.unlock()
    }

    public init(directory: URL? = nil) {
        let dir = directory ?? AppSupportDirectory.url

        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("store.json")

        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                self._data = try decoder.decode(StoreData.self, from: data)
            } catch {
                // Log the error so we know WHY decoding failed — this was silently wiping the store
                NSLog("[JSONStore] ERROR: Failed to decode store.json: \(error.localizedDescription)")
                NSLog("[JSONStore] Backing up corrupt store to store.json.bak")
                let backupURL = dir.appendingPathComponent("store.json.bak")
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
                self._data = StoreData()
            }
        } else {
            self._data = StoreData()
        }
        // Seed the external-writer tripwire baseline (CROW-759): the file we just
        // loaded (if any) is our starting point, so a change before the first
        // `mutate` is attributable to another writer. `nil` when no file exists yet.
        self.lastKnownStat = Self.statSignature(fileURL)
    }

    public func mutate(_ transform: (inout StoreData) -> Void) {
        // External-writer tripwire (CROW-759): if store.json changed under us since
        // our last authored write, a second process is writing it — log LOUD before
        // we overwrite the whole file with our snapshot and wipe its changes.
        checkForExternalWrite(context: "mutate")

        // Apply the mutation and snapshot under `lock`, then release it before
        // touching disk. Holding `lock` across the encode + atomic write blocks
        // every reader (`data`) and other mutators for the full duration of the
        // I/O — exactly the contention that froze the UI when many sessions
        // updated at once (#304).
        lock.lock()
        transform(&_data)
        writeSeq &+= 1
        let mySeq = writeSeq
        let snapshot = _data
        lock.unlock()

        // Serialize writes on a separate lock so disk order matches mutation
        // order. Each save carries its sequence; a snapshot that is already
        // stale (a newer one has been written) is dropped. Because the
        // highest-sequence snapshot reflects every mutation up to that point,
        // coalescing redundant writes can never drop data.
        writeLock.lock()
        defer { writeLock.unlock() }
        guard mySeq > lastWrittenSeq else { return }
        lastWrittenSeq = mySeq
        Self.save(snapshot, to: fileURL)
        // Record the signature of the file we just authored so the next tripwire
        // check compares against our own write, not a stale baseline (CROW-759).
        lastKnownStat = Self.statSignature(fileURL)
    }

    /// Fire the external-writer tripwire if `store.json` changed under us since our
    /// last authored write. Diagnostic safety net for CROW-759: the daemon's
    /// store-writer flock should make a second writer impossible, so if this ever
    /// logs, a bypass slipped through and is now attributable (stamped with pid).
    private func checkForExternalWrite(context: String) {
        writeLock.lock()
        let known = lastKnownStat
        writeLock.unlock()
        guard let known else { return }                                  // no authored write yet
        guard let current = Self.statSignature(fileURL) else { return }  // gone/unreadable — skip
        guard current != known else { return }
        NSLog("[JSONStore] EXTERNAL WRITE DETECTED (\(context)) — a second writer is touching "
            + "store.json (pid \(ProcessInfo.processInfo.processIdentifier)); the single-writer invariant "
            + "is violated and the next whole-file write will clobber it (CROW-759). "
            + "expected mtime=\(known.mtime) size=\(known.size), found mtime=\(current.mtime) size=\(current.size)")
    }

    /// mtime + size of the file at `url`, or nil if it doesn't exist / can't be
    /// stat'd. Cheap change-detection for the external-writer tripwire.
    private static func statSignature(_ url: URL) -> StatSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? Int) ?? 0
        return StatSignature(mtime: mtime, size: size)
    }

    private static func save(_ data: StoreData, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let jsonData = try? encoder.encode(data) else {
            NSLog("[JSONStore] ERROR: Failed to encode store data")
            return
        }
        do {
            try jsonData.write(to: url, options: .atomic)
            // Restrict store file to owner-only access
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("[JSONStore] ERROR: Failed to write store.json: \(error.localizedDescription)")
        }
    }
}
