import Foundation

/// The Google Antigravity (`agy`) app-data home, resolved the way Crow's other
/// harness homes are (`CodexHome`/`GrokHome`): honor `$GEMINI_HOME` when set and
/// non-empty, otherwise `~/.gemini`, then descend into `antigravity-cli` — the
/// CLI's own data root (the *IDE* uses a separate `~/.gemini/antigravity-ide/`
/// tree).
///
/// ⚠️ **Docs-derived, pending live-verify (CROW-1107).** `agy` is not installable
/// on Crow's dev machines (closed-source, Google-Sign-In/GCP-authed), so these
/// paths come from Antigravity CLI docs + community tooling (`agy-explore`,
/// `agentgrep`, the `antigravity-conversation-fix` recovery tool), **not**
/// first-party on-disk capture. `$GEMINI_HOME` is honored defensively in case a
/// user relocates the tree; confirm the exact root against a live `agy` before
/// promoting Antigravity out of Tier-2 (ADR 0015).
public enum AntigravityHome {
    /// The Antigravity CLI app-data root. `environment` is injectable for tests.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let base: String
        if let env = environment["GEMINI_HOME"], !env.isEmpty {
            base = env
        } else {
            base = NSString(string: "~/.gemini").expandingTildeInPath
        }
        return (base as NSString).appendingPathComponent("antigravity-cli")
    }

    /// `<home>/brain` — where `agy` pools every conversation's durable transcript,
    /// keyed only by conversation id (flat/global, like Codex's `sessions`).
    public static func brainDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (path(environment: environment) as NSString).appendingPathComponent("brain")
    }

    /// The durable NDJSON transcript for a conversation:
    /// `<brain>/<id>/.system_generated/logs/transcript_full.jsonl`. This is the
    /// full log; the sibling `transcript.jsonl` is the known-buggy truncated one,
    /// so it is never used.
    public static func transcriptPath(
        conversationID: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        transcriptPath(conversationID: conversationID, brainDir: brainDir(environment: environment))
    }

    /// Same, against an explicit brain dir (test seam / backfill scanner).
    public static func transcriptPath(conversationID: String, brainDir: String) -> String {
        var p = (brainDir as NSString).appendingPathComponent(conversationID)
        p = (p as NSString).appendingPathComponent(".system_generated")
        p = (p as NSString).appendingPathComponent("logs")
        p = (p as NSString).appendingPathComponent("transcript_full.jsonl")
        return p
    }

    /// The conversation-id directory a `transcript_full.jsonl` lives under — the
    /// inverse of `transcriptPath`, walking three parents up (`logs` →
    /// `.system_generated` → `<id>`). Used by the backfill scanner.
    public static func conversationID(forTranscript file: URL) -> String? {
        let id = file
            .deletingLastPathComponent()   // …/logs
            .deletingLastPathComponent()   // …/.system_generated
            .deletingLastPathComponent()   // …/<id>
            .lastPathComponent
        return id.isEmpty ? nil : id
    }
}

/// Crow's runtime `conversationId → worktree` map for Antigravity (CROW-1107).
///
/// Antigravity's transcript records no cwd on any line, so it is **not**
/// cwd-attributable by the shared `cwdFilter` path the way Codex's rollouts are
/// (CROW-1097). The attribution Crow *does* have is exact and non-guessed: it
/// launched `agy` in a known worktree, and each Antigravity hook fires with that
/// session's `--session <uuid>` baked into `.agents/hooks.json`. The hook stdin
/// payload additionally carries the `conversationId`, which names the transcript's
/// `brain/<id>/…` directory. So the daemon records `conversationId → worktree` as
/// hooks fire (`record(...)`, from `CrowEngine`'s `hook-event` handler), and
/// `AntigravityAgent.logSources` reads it back to return exactly this worktree's
/// transcripts — a file with no map entry is dropped, never guessed (the same
/// invariant as Codex's cwd filter).
///
/// Lives in `CrowCore` because both the writer (`CrowEngine`) and the reader
/// (`CrowAntigravity`) import CrowCore, and CrowEngine does not depend on
/// CrowAntigravity.
///
/// ⚠️ **Docs-derived, pending live-verify (CROW-1107).** See `AntigravityHome`.
/// The worktree is taken from Crow's own session ownership (never the payload), so
/// only `conversationId` is trusted from the un-verified hook payload — and even
/// that only *selects* a transcript, so a wrong payload field name yields "no map
/// entry" (⇒ nothing uploaded for that conversation), never a misattribution.
public struct AntigravityConversationMap: Codable, Equatable, Sendable {
    /// One conversation's attribution.
    public struct Entry: Codable, Equatable, Sendable {
        /// The worktree Crow launched `agy` in for this conversation — taken from
        /// Crow's own session ownership, never the hook payload.
        public var worktreePath: String
        /// The transcript path the hook payload named, if any — retained purely as
        /// **untrusted provenance**, so whoever live-verifies against a real `agy`
        /// can compare what the hook reported against the derived brain-dir template
        /// (CROW-1107). It is **never** used to locate the collectable file: the
        /// durable `transcript_full.jsonl` is always derived from the conversation id
        /// + `brainDir` (`transcripts(forWorktreePath:brainDir:)`), so a payload that
        /// points outside `brainDir`, or uses a `~` the filesystem won't expand,
        /// can't redirect or silently drop a collection (CROW-1107 review).
        public var transcriptPath: String?
        /// When the entry was last recorded, epoch seconds.
        public var updatedAt: Double

        public init(worktreePath: String, transcriptPath: String? = nil, updatedAt: Double = 0) {
            self.worktreePath = worktreePath
            self.transcriptPath = transcriptPath
            self.updatedAt = updatedAt
        }
    }

    public var version: Int
    public var conversations: [String: Entry]

    public init(version: Int = 1, conversations: [String: Entry] = [:]) {
        self.version = version
        self.conversations = conversations
    }

    // MARK: - Reading (synchronous — the `logSources` reader path is synchronous)

    /// The global map file, in Crow's state dir (`~/.local/share/crow/`, the same
    /// root as `crow.sock`). Global and devRoot-independent because the reader
    /// (`AntigravityAgent.logSources`) has no devRoot, and worktree paths are
    /// absolute and unique across dev roots anyway. `testMapURLOverride` redirects
    /// it in tests so nothing touches the real state dir.
    public static func defaultMapURL() -> URL {
        if let override = testMapURLOverride { return override }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow", isDirectory: true)
            .appendingPathComponent("antigravity-conversations.json")
    }

    /// Load the persisted map (empty on any read/parse failure — best-effort).
    public static func load(mapURL: URL = defaultMapURL()) -> AntigravityConversationMap {
        guard let data = try? Data(contentsOf: mapURL),
              let map = try? JSONDecoder().decode(AntigravityConversationMap.self, from: data)
        else { return AntigravityConversationMap() }
        return map
    }

    /// Absolute `transcript_full.jsonl` paths for the entries mapped to
    /// `worktreePath` (path-standardized on both sides), **existence-checked** so a
    /// missing file is dropped — never guessed. Sorted oldest-modified first, so a
    /// worktree spanning several conversations concatenates chronologically.
    public func transcripts(
        forWorktreePath worktreePath: String,
        brainDir: String = AntigravityHome.brainDir()
    ) -> [String] {
        let want = (worktreePath as NSString).standardizingPath
        guard !want.isEmpty else { return [] }
        let fm = FileManager.default
        var matches: [(path: String, mtime: Date)] = []
        for (conversationID, entry) in conversations
        where (entry.worktreePath as NSString).standardizingPath == want {
            // The collectable file is ALWAYS derived from the conversation id +
            // `brainDir` — never from the recorded `transcriptPath`, which is
            // untrusted hook provenance (see `Entry.transcriptPath`). This confines
            // every collected path to `brainDir` and sidesteps the payload's `~`
            // (which `fileExists` won't expand) and any out-of-tree location. A
            // conversation id that isn't a safe single path component is dropped,
            // never interpolated into a path (CROW-1107 review).
            guard Self.isPathSafeConversationID(conversationID) else { continue }
            let candidate = AntigravityHome.transcriptPath(conversationID: conversationID, brainDir: brainDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue else { continue }
            let mtime = (try? URL(fileURLWithPath: candidate)
                .resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            matches.append((candidate, mtime))
        }
        return matches.sorted { $0.mtime < $1.mtime }.map { $0.path }
    }

    /// Whether `id` is a safe single path component to interpolate into the
    /// brain-dir template — rejecting empty, `.` / `..`, and any id containing a
    /// path separator or NUL, so an untrusted hook conversation id can never escape
    /// `brainDir` (CROW-1107 review). Antigravity conversation ids are UUIDs, so a
    /// real id is never rejected.
    static func isPathSafeConversationID(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != ".." else { return false }
        return !id.contains("/") && !id.contains("\\") && !id.contains("\u{0}")
    }

    // MARK: - Writing (synchronous, NSLock-guarded, dedupe-cached)

    private static let lock = NSLock()
    /// Skips the load-mutate-save when the `(map file, conversationId) → (worktree,
    /// transcript)` mapping is already on file, so only the *first* hook event per
    /// conversation writes — the frequent `PostToolUse` stream costs nothing after.
    /// Keyed by map path so tests using different files never collide.
    private nonisolated(unsafe) static var recordedCache: [String: String] = [:]
    /// Test-only redirect for `defaultMapURL()`.
    nonisolated(unsafe) static var testMapURLOverride: URL?

    /// Record (or refresh) `conversationID → worktreePath` (+ an optional
    /// `transcriptPath` hint), best-effort. Deduped in-memory and serialized with
    /// `lock`; a write failure is swallowed (worst case: the transcript is picked
    /// up a tick later, or not at all — never a session failure). Returns whether a
    /// disk write actually happened.
    @discardableResult
    public static func record(
        conversationID: String,
        worktreePath: String,
        transcriptPath: String? = nil,
        now: Double = Date().timeIntervalSince1970,
        mapURL: URL = defaultMapURL()
    ) -> Bool {
        let conv = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let wt = worktreePath.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject an unsafe conversation id up front so it never reaches the map (it
        // would only be dropped at read time anyway — CROW-1107 review).
        guard !wt.isEmpty, isPathSafeConversationID(conv) else { return false }
        let transcript = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = (transcript?.isEmpty == false) ? transcript : nil

        lock.lock()
        defer { lock.unlock() }

        let cacheKey = mapURL.path + "\u{0}" + conv
        let cacheVal = wt + "\u{0}" + (normalizedTranscript ?? "")
        if recordedCache[cacheKey] == cacheVal { return false }

        var map = load(mapURL: mapURL)
        let existing = map.conversations[conv]
        // Preserve a previously-recorded transcript hint when this event omits one.
        let effectiveTranscript = normalizedTranscript ?? existing?.transcriptPath
        // No meaningful change (only `updatedAt` would move) ⇒ skip the write, but
        // still cache: disk already matches, so future identical hooks can no-op.
        if existing?.worktreePath == wt, existing?.transcriptPath == effectiveTranscript {
            recordedCache[cacheKey] = cacheVal
            return false
        }
        map.conversations[conv] = Entry(
            worktreePath: wt, transcriptPath: effectiveTranscript, updatedAt: now)

        do {
            let dir = mapURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(map)
            try data.write(to: mapURL, options: [.atomic])
            // Cache ONLY after a durable write. A failed first persist must not
            // poison the cache — otherwise later hooks for this conversation would
            // short-circuit as a cache hit and never retry (CROW-1107 review).
            recordedCache[cacheKey] = cacheVal
            return true
        } catch {
            CrowLog.info("[AntigravityConversationMap] failed to persist \(mapURL.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Reset the dedupe cache and the test URL override (tests only).
    static func resetForTesting() {
        lock.lock()
        recordedCache.removeAll()
        testMapURLOverride = nil
        lock.unlock()
    }
}
