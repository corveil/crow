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
        /// The transcript path the hook payload named, if any — an optional hint;
        /// the durable `transcript_full.jsonl` is derived from the conversation id
        /// regardless (see `preferredTranscript`).
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
            let candidate = Self.preferredTranscript(
                entry: entry, conversationID: conversationID, brainDir: brainDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue else { continue }
            let mtime = (try? URL(fileURLWithPath: candidate)
                .resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            matches.append((candidate, mtime))
        }
        return matches.sorted { $0.mtime < $1.mtime }.map { $0.path }
    }

    /// The `transcript_full.jsonl` for an entry: the sibling of a recorded
    /// `transcriptPath` when present (the recorded *directory* is authoritative
    /// even if the recorded file was the truncated `transcript.jsonl`), else
    /// derived from the conversation id + `brainDir`.
    static func preferredTranscript(entry: Entry, conversationID: String, brainDir: String) -> String {
        if let recorded = entry.transcriptPath, !recorded.isEmpty {
            let dir = (recorded as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                return (dir as NSString).appendingPathComponent("transcript_full.jsonl")
            }
        }
        return AntigravityHome.transcriptPath(conversationID: conversationID, brainDir: brainDir)
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
        guard !conv.isEmpty, !wt.isEmpty else { return false }
        let transcript = transcriptPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTranscript = (transcript?.isEmpty == false) ? transcript : nil

        lock.lock()
        defer { lock.unlock() }

        let cacheKey = mapURL.path + "\u{0}" + conv
        let cacheVal = wt + "\u{0}" + (normalizedTranscript ?? "")
        if recordedCache[cacheKey] == cacheVal { return false }
        recordedCache[cacheKey] = cacheVal

        var map = load(mapURL: mapURL)
        let existing = map.conversations[conv]
        // Preserve a previously-recorded transcript hint when this event omits one.
        let effectiveTranscript = normalizedTranscript ?? existing?.transcriptPath
        // No meaningful change (only `updatedAt` would move) ⇒ skip the write.
        if existing?.worktreePath == wt, existing?.transcriptPath == effectiveTranscript {
            return false
        }
        map.conversations[conv] = Entry(
            worktreePath: wt, transcriptPath: effectiveTranscript, updatedAt: now)

        do {
            let dir = mapURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(map)
            try data.write(to: mapURL, options: [.atomic])
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
