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
    /// Manager-session weekly usage rollups (#745), keyed by week-start
    /// "yyyy-MM-dd". Optional for the same backward-compat reason as
    /// `hookStates`. Merge-only: weeks that age out of telemetry retention
    /// keep their persisted values; only weeks the DB still covers are
    /// overwritten.
    public var managerUsageWeekly: [String: ManagerWeeklyUsage]?

    public init(
        sessions: [Session] = [],
        worktrees: [SessionWorktree] = [],
        links: [SessionLink] = [],
        terminals: [SessionTerminal] = [],
        hookStates: [String: PersistedHookState]? = nil,
        analyticsSnapshots: [String: SessionAnalyticsSnapshot]? = nil,
        prAttributions: [String: PRSessionAttribution]? = nil,
        managerUsageWeekly: [String: ManagerWeeklyUsage]? = nil
    ) {
        self.sessions = sessions
        self.worktrees = worktrees
        self.links = links
        self.terminals = terminals
        self.hookStates = hookStates
        self.analyticsSnapshots = analyticsSnapshots
        self.prAttributions = prAttributions
        self.managerUsageWeekly = managerUsageWeekly
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
    /// (mtime, size) of `store.json` as of our own last write/reload, or nil
    /// until we've touched it. Guarded by `writeLock`. Lets us notice a SECOND
    /// process writing the file out from under us: `JSONStore.mutate` rewrites
    /// the whole `StoreData`, so a stray external write silently clobbers our
    /// view. The daemon enforces a single writer via an flock (#759); this is
    /// the diagnostic tripwire that makes any future bypass attributable in the
    /// console the user already tails.
    private nonisolated(unsafe) var lastWrittenSignature: FileSignature?

    /// A cheap fingerprint of `store.json` — enough to spot that *someone else*
    /// rewrote it since we last did (#759).
    private struct FileSignature: Equatable {
        let modified: Date
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

    /// The default on-disk directory for `store.json` — the shared app-support
    /// dir, fixed regardless of any `--socket`. The daemon locks a file beside
    /// the store here to enforce a single store writer (#759).
    public static var defaultDirectory: URL { AppSupportDirectory.url }

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
        // Adopting a disk copy we didn't write is exactly the single-writer
        // violation the tripwire watches for; check + re-baseline before we
        // overwrite our in-memory view (#759).
        writeLock.lock()
        detectExternalWrite(context: "reload")
        lastWrittenSignature = currentSignature()
        writeLock.unlock()
        lock.lock()
        _data = decoded
        lock.unlock()
    }

    public init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            // Test-isolation guardrail (#764, ADR 0012): a bare `JSONStore()`
            // under a test process would open the LIVE store
            // (~/Library/Application Support/crow/store.json) and a subsequent
            // full-snapshot `mutate` would wipe the developer's real sessions —
            // exactly the incident this ticket fixed. Trap loudly instead of
            // silently mutating live data. Only the default (nil-directory) path
            // is gated, so explicit-temp-dir test stores and production `crowd`
            // (never run under a test runner) are both unaffected.
            Self.trapIfConstructingLivePathUnderTests()
            dir = AppSupportDirectory.url
        }

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

    /// Fail-fast when a `JSONStore()` with no explicit `directory:` is built
    /// inside a test process. Covers the runners Crow's suites actually use:
    ///
    /// - **swift-testing via SwiftPM** (`swift test` / `make test`, the path in
    ///   #764): the host executable is `swiftpm-testing-helper`; XCTest is *not*
    ///   linked and no XCTest env vars are set, so we key off the runner name.
    /// - **XCTest / Xcode**: `XCTestCase` is linked into the test bundle, and the
    ///   host runs from an `.xctest` bundle with `XCTestConfigurationFilePath` set.
    ///
    /// None of these signals are present in the shipping `crowd`/app binaries, so
    /// production is never gated. See `docs/adr/0012-tests-never-touch-live-data.md`.
    private static func isRunningUnderTests() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        let arg0 = CommandLine.arguments.first
        let runnerNames: Set<String> = ["swiftpm-testing-helper", "xctest"]
        if let base = (arg0 as NSString?)?.lastPathComponent, runnerNames.contains(base) { return true }
        if runnerNames.contains(ProcessInfo.processInfo.processName) { return true }
        if arg0?.contains(".xctest") == true { return true }
        return false
    }

    private static func trapIfConstructingLivePathUnderTests() {
        guard isRunningUnderTests() else { return }
        fatalError("""
            JSONStore() was constructed with the default LIVE store path \
            (\(AppSupportDirectory.url.appendingPathComponent("store.json").path)) \
            under a test process. A full-store `mutate` would clobber the \
            developer's real sessions (#764). Inject an explicit temp directory \
            instead — e.g. `JSONStore.temporary()` or \
            `JSONStore(directory: NSTemporaryDirectory()…)`. See ADR 0012.
            """)
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
        // Before overwriting the whole file, notice if a second writer touched
        // it since our last write — otherwise its records vanish silently (#759).
        detectExternalWrite(context: "before write")
        lastWrittenSeq = mySeq
        Self.save(snapshot, to: fileURL)
        lastWrittenSignature = currentSignature()
    }

    /// Current `(mtime, size)` fingerprint of `store.json`, or nil if it can't
    /// be stat'd (missing file / error). Diagnostic-only (#759).
    private func currentSignature() -> FileSignature? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        return FileSignature(modified: modified, size: size)
    }

    /// If `store.json` changed since our last write/reload, a SECOND process is
    /// writing it — log LOUD and pid-stamped so the bypass is immediately
    /// attributable. Diagnostic only: it never alters behavior (the flock in
    /// `crowd` is the actual enforcement — #759). No-op until we've written once
    /// (`lastWrittenSignature == nil`). Must be called under `writeLock`.
    private func detectExternalWrite(context: String) {
        guard let expected = lastWrittenSignature, let actual = currentSignature(),
              actual != expected else { return }
        NSLog(
            "[JSONStore] EXTERNAL WRITE DETECTED (%@): store.json at %@ changed under pid %d "
                + "— a second writer is touching store.json (expected mtime=%@ size=%d, "
                + "found mtime=%@ size=%d). Whole-file writes mean the losing writer's sessions "
                + "vanish; only ONE crowd may write this store.",
            context, fileURL.path, getpid(),
            "\(expected.modified)", expected.size, "\(actual.modified)", actual.size)
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
