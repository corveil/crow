import CrowCore
import CrowIPC
import Foundation

/// The `context` object on `get-session` and `list-sessions` (CROW-1493): how
/// many tokens the session's agent carries, and whether its prompt cache has
/// likely expired so the next message rebuilds it.
///
/// Read from the transcript the agent already writes, found by the session's
/// recorded conversation id (``HarnessTranscriptLocator``) and parsed with the
/// Chat view's usage rules (``ContextSnapshotReader``). Claude Code and Codex
/// only; other harnesses report `null`.
///
/// Unlike the Chat view, this never guesses the newest transcript in the cwd
/// when no id is recorded yet: a guess can be a sibling conversation's numbers,
/// and listing the directory on every `list-sessions` poll isn't free. Hooks
/// record the id on the agent's first event, so only a session that hasn't
/// sent one yet reports `null`.
///
/// Gathering the source needs `AppState` (MainActor); reading the file must
/// stay off the MainActor (#892), so the two halves are separate calls.
public enum SessionContextReport {

    /// Where a session's transcript is, gathered on the MainActor.
    public struct Source: Sendable, Equatable {
        public var sessionID: UUID
        public var agentKind: AgentKind
        public var conversationID: String?
        public var cwd: String
    }

    /// The transcript found for a ``Source``.
    public struct Located: Sendable, Equatable {
        public var path: String
        public var format: ChatTranscriptFormat
    }

    /// The session's transcript source, or nil for a harness this can't read
    /// or a session whose agent hasn't reported a conversation id yet.
    @MainActor
    public static func source(for session: Session, appState: AppState) -> Source? {
        guard session.agentKind == .claudeCode || session.agentKind == .codex,
              let conversationID = session.harnessConversationID else { return nil }
        let cwd = AgentStateReport.agentTerminal(for: session, appState: appState)?.cwd
            ?? appState.primaryWorktree(for: session.id)?.worktreePath
            ?? ""
        return Source(
            sessionID: session.id, agentKind: session.agentKind, conversationID: conversationID, cwd: cwd)
    }

    /// Resolve `source` to its transcript file. File-system reads: call off
    /// the MainActor.
    static func locate(_ source: Source, roots: HarnessTranscriptLocator.Roots = .live) -> Located? {
        HarnessTranscriptLocator.path(
            kind: source.agentKind, conversationID: source.conversationID, cwd: source.cwd, roots: roots
        ).map { Located(path: $0, format: source.agentKind == .codex ? .codex : .claude) }
    }

    /// The snapshot for `source`, through the shared stat-keyed cache. Nil when
    /// there is no transcript or it holds no usage yet. Off the MainActor.
    public static func snapshot(for source: Source) -> (ContextSnapshot, Located)? {
        snapshot(for: source, roots: .live, cache: .shared)
    }

    static func snapshot(
        for source: Source, roots: HarnessTranscriptLocator.Roots, cache: ContextSnapshotCache
    ) -> (ContextSnapshot, Located)? {
        // A Codex rollout is found by walking its date tree, so the resolved
        // path is remembered per conversation and only re-checked with a stat.
        let key = "\(source.agentKind.rawValue)|\(source.conversationID ?? "")|\(source.cwd)"
        let located: Located
        if let known = cache.located(key), FileManager.default.fileExists(atPath: known.path) {
            located = known
        } else if let found = locate(source, roots: roots) {
            cache.remember(found, for: key)
            located = found
        } else {
            return nil
        }
        guard let snap = cache.snapshot(path: located.path, format: located.format) else { return nil }
        return (snap, located)
    }

    /// Snapshots for many sources at once, keyed by session id. Off the MainActor.
    public static func snapshots(for sources: [Source]) -> [UUID: (ContextSnapshot, Located)] {
        var out: [UUID: (ContextSnapshot, Located)] = [:]
        for source in sources {
            if let hit = snapshot(for: source) { out[source.sessionID] = hit }
        }
        return out
    }

    /// The two flags automation gates on (CROW-1501), defined once so a gate
    /// and the `context` JSON can't disagree.
    public struct Warmth: Sendable, Equatable {
        /// `cache_expired`: nil when the lifetime or last call is unknown.
        public var cacheExpired: Bool?
        /// `large`: tokens ≥ the configured threshold.
        public var large: Bool

        public init(cacheExpired: Bool?, large: Bool) {
            self.cacheExpired = cacheExpired
            self.large = large
        }

        /// The next message would re-write a large context at the cache-write
        /// price. Unknown expiry counts as warm: a gate never acts on a guess.
        public var coldAndLarge: Bool { cacheExpired == true && large }
    }

    /// `cache_expired` and `large` for a snapshot, nil when there is none.
    public static func warmth(_ snap: ContextSnapshot?, largeThreshold: Int, now: Date = Date()) -> Warmth? {
        guard let snap else { return nil }
        return Warmth(cacheExpired: snap.cacheLikelyExpired(now: now), large: (snap.tokens ?? 0) >= largeThreshold)
    }

    /// The JSON object, or `null` when nothing was found.
    ///
    /// - `tokens`: prompt tokens of the latest model call (after a compaction
    ///   with no call since, the compaction's result; null if unrecorded)
    /// - `max_tokens`, `model`: the window and model, when known
    /// - `last_request_at`, `idle_seconds`: when the cache was last refreshed
    /// - `cache_ttl_seconds`: the cache lifetime the transcript records
    /// - `cache_expired`: idle past that lifetime, so the next message
    ///   re-writes the whole context (null when either input is unknown)
    /// - `large`: `tokens` ≥ `contextCompaction.minContextTokens`
    /// - `compacted_at`: set when the transcript ends in a compaction
    public static func json(
        _ hit: (ContextSnapshot, Located)?, largeThreshold: Int, now: Date = Date()
    ) -> JSONValue {
        guard let snap = hit?.0,
              let warmth = warmth(snap, largeThreshold: largeThreshold, now: now) else { return .null }
        let fmt = ISO8601DateFormatter()
        func opt(_ v: Int?) -> JSONValue { v.map { .int($0) } ?? .null }
        return .object([
            "tokens": opt(snap.tokens),
            "max_tokens": opt(snap.maxTokens),
            "model": snap.model.map { .string($0) } ?? .null,
            "last_request_at": snap.lastRequestAt.map { .string(fmt.string(from: $0)) } ?? .null,
            "idle_seconds": opt(snap.idleSeconds(now: now).map { Int($0) }),
            "cache_ttl_seconds": opt(snap.cacheTTL.map { Int($0) }),
            "cache_expired": warmth.cacheExpired.map { .bool($0) } ?? .null,
            "large": .bool(warmth.large),
            "compacted_at": snap.compactedAt.map { .string(fmt.string(from: $0)) } ?? .null,
        ])
    }
}

/// Snapshots keyed by transcript path, reused while the file's size and
/// modification time are unchanged. `list-sessions` is polled every few
/// seconds by every open browser, and an idle session's transcript doesn't
/// change, so most polls cost one `stat` per session.
final class ContextSnapshotCache: @unchecked Sendable {
    static let shared = ContextSnapshotCache()

    private struct Entry {
        var size: Int
        var modified: Date
        var snapshot: ContextSnapshot?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var locatedByKey: [String: SessionContextReport.Located] = [:]
    /// Drop a whole map past this many keys. A session's transcript path
    /// changes on `/clear`, so old paths would otherwise accumulate for weeks.
    private let maxEntries = 512

    func located(_ key: String) -> SessionContextReport.Located? {
        lock.lock()
        defer { lock.unlock() }
        return locatedByKey[key]
    }

    func remember(_ located: SessionContextReport.Located, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if locatedByKey.count >= maxEntries { locatedByKey.removeAll(keepingCapacity: true) }
        locatedByKey[key] = located
    }

    func snapshot(path: String, format: ChatTranscriptFormat) -> ContextSnapshot? {
        // `attributesOfItem`, not `URL.resourceValues`: the latter caches per
        // URL instance and can report a stale size.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        lock.lock()
        if let hit = entries[path], hit.size == size, hit.modified == modified {
            lock.unlock()
            return hit.snapshot
        }
        lock.unlock()
        // Read outside the lock: two polls may parse the same file once each,
        // which is cheaper than serializing every session's read.
        let snap = (try? ContextSnapshotReader.read(path: path, format: format)) ?? nil
        lock.lock()
        if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
        entries[path] = Entry(size: size, modified: modified, snapshot: snap)
        lock.unlock()
        return snap
    }
}
