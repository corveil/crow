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

    public init(
        sessions: [Session] = [],
        worktrees: [SessionWorktree] = [],
        links: [SessionLink] = [],
        terminals: [SessionTerminal] = [],
        hookStates: [String: PersistedHookState]? = nil
    ) {
        self.sessions = sessions
        self.worktrees = worktrees
        self.links = links
        self.terminals = terminals
        self.hookStates = hookStates
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

    public var data: StoreData {
        lock.lock()
        defer { lock.unlock() }
        return _data
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
    }

    public func mutate(_ transform: (inout StoreData) -> Void) {
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
