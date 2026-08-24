#if canImport(SQLite3)
import SQLite3
#endif
import Foundation

/// One OpenCode session read from the `opencode.db` SQLite store (CROW-1096). Since
/// OpenCode 1.17 a session is a row in the relational `session` table (not a JSON
/// object-store anchor), with its scattered content in the `message` and `part`
/// tables keyed by `session_id` / `message_id`. This is the parsed session row; the
/// transcript is reassembled on demand (`OpenCodeStore.reassemble`).
public struct OpenCodeStoreSession: Sendable, Equatable {
    /// The session id (`ses_…`) — the transcript's identity and upload `{uid}`.
    public var id: String
    /// The working directory the session ran in, from `session.directory` (stored
    /// as an absolute path). `nil` only for a legacy row that persisted an empty
    /// directory — such a session is dropped, never guessed (the cwd→session
    /// attribution invariant, CROW-1089).
    public var cwd: String?
    /// The parent session id when this is a **child** (subagent / task) session.
    /// Non-empty ⇒ the session belongs to a parent — excluded from upload for parity
    /// with Claude's exclusion of `subagents/agent-*.jsonl`.
    public var parentID: String?
    /// The session title, when recorded — a metadata-name fallback.
    public var title: String?
    /// `session.time_created` / `time_updated` in epoch **milliseconds**.
    public var createdMs: Double?
    public var updatedMs: Double?

    public init(
        id: String, cwd: String? = nil, parentID: String? = nil,
        title: String? = nil, createdMs: Double? = nil, updatedMs: Double? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.parentID = parentID
        self.title = title
        self.createdMs = createdMs
        self.updatedMs = updatedMs
    }

    /// Whether this is a child (subagent) session — one that belongs to a parent.
    public var isChild: Bool {
        guard let parentID else { return false }
        return !parentID.isEmpty
    }
}

/// Reads OpenCode's `opencode.db` SQLite store and reassembles a session's rows into
/// one ordered NDJSON transcript (CROW-1096).
///
/// Schema (verified against `sst/opencode` `packages/core/src/session/sql.ts`, the
/// store current OpenCode 1.17.10+ writes):
///
///   session(id TEXT PK, parent_id TEXT, directory TEXT, title TEXT,
///           time_created INT, time_updated INT, …)
///   message(id TEXT PK, session_id TEXT, time_created INT, data JSON TEXT, …)
///   part(id TEXT PK, message_id TEXT, session_id TEXT, data JSON TEXT, …)
///
/// `session.directory` is the absolute cwd (attribution), `parent_id` marks a child
/// session. Reassembly emits the session row as a header line, then each message in
/// `(time_created, id)` order — the same order as the DB's
/// `message_session_time_created_id_idx` — immediately followed by its parts in `id`
/// order (`part_message_id_id_idx`). OpenCode ids are monotonic-ascending, so an id
/// sort is chronological. Each on-disk `data` payload is already a JSON object; the
/// reassembler re-serializes it compact with sorted keys so the output is stable,
/// single-line NDJSON.
///
/// **Platform.** The reader needs SQLite. The Crow daemon that runs the collector is
/// macOS-only, where `SQLite3` is an SDK module; on Linux (CI compiles `crowd`/`crow`
/// there but runs no daemon) the reader compiles to a no-op returning nothing, and
/// its behavioral tests are gated to `canImport(SQLite3)`.
public enum OpenCodeStore {

#if canImport(SQLite3)

    // MARK: - Enumerate sessions (backfill scan)

    /// Every session row in the database, in no particular order. Used by the
    /// backfill scanner to reconstruct one `BackfillSession` per session. Returns
    /// `[]` for a missing/unreadable database.
    public static func sessions(databasePath: String) -> [OpenCodeStoreSession] {
        withDatabase(databasePath) { db in readSessions(db, whereClause: nil, arg: nil) } ?? []
    }

    /// The recorded cwd for one session id (nil for a child, a missing directory, or
    /// a missing row) — the attribution probe used when reconstructing a single
    /// backfill session.
    public static func cwd(databasePath: String, sessionID: String) -> String? {
        withDatabase(databasePath) { db in
            readSessions(db, whereClause: "id = ?", arg: sessionID).first
        }?.flatMap { $0.isChild ? nil : $0.cwd }
    }

    // MARK: - Normalize (live collector: all matching sessions)

    /// Reassemble every **top-level** session in `databaseFiles` whose recorded cwd
    /// equals `cwd`, concatenated chronologically into one NDJSON transcript bounded
    /// by `maxBytes` (CROW-1096). Child/subagent sessions and cwd-less sessions are
    /// dropped. `nil` when nothing matched or the database is unreadable.
    public static func normalizeSessions(
        databaseFiles: [URL], cwd: String, maxBytes: Int
    ) -> NormalizedTranscript? {
        guard maxBytes > 0 else { return nil }
        let want = (cwd as NSString).standardizingPath
        guard !want.isEmpty else { return nil }

        var out = Data()
        var truncated = false
        for file in databaseFiles {
            let (data, wasTruncated) = withDatabase(file.path) { db -> (Data, Bool) in
                let matches = readSessions(db, whereClause: nil, arg: nil)
                    .filter { !$0.isChild }
                    .filter { ($0.cwd as NSString?)?.standardizingPath == want }
                    .sorted { ($0.createdMs ?? 0) < ($1.createdMs ?? 0) }
                return emitSessions(matches, db: db, into: &out, maxBytes: maxBytes)
            } ?? (out, truncated)
            out = data
            truncated = truncated || wasTruncated
            if truncated { break }
        }
        return TranscriptNormalizer.finalize(out, truncated: truncated)
    }

    // MARK: - Quiescence (live collector)

    /// The most recent write time (as a `Date`) for the cwd-matched top-level
    /// sessions in `databaseFiles` — the collector's quiescence signal (CROW-1096
    /// review). For each matched session it takes the max of the session row's
    /// `time_updated`/`time_created` and the newest `message`/`part` `time_created`
    /// (those tables are append-only, so their timestamps move on every new turn even
    /// if the session row itself isn't rewritten).
    ///
    /// This replaces the `opencode.db` **file** mtime for OpenCode, which is wrong on
    /// two counts: OpenCode runs the store in WAL mode, so a commit lands in the
    /// `-wal` sidecar without bumping the main file's mtime (an in-progress session
    /// would look idle and get a premature, write-once-permanent snapshot); and one
    /// database is shared by every worktree, so the file mtime is machine-global, not
    /// this worktree's activity. A SQLite read sees WAL-committed rows, and the cwd
    /// filter scopes it to this worktree. `nil` when nothing matches or the database
    /// is unreadable (the caller then does not gate on a quiet period).
    public static func newestActivity(databaseFiles: [URL], cwd: String) -> Date? {
        let want = (cwd as NSString).standardizingPath
        guard !want.isEmpty else { return nil }
        var newestMs: Double?
        for file in databaseFiles {
            _ = withDatabase(file.path) { db -> Void in
                let matched = readSessions(db, whereClause: nil, arg: nil)
                    .filter { !$0.isChild }
                    .filter { ($0.cwd as NSString?)?.standardizingPath == want }
                for s in matched {
                    consider(&newestMs, s.updatedMs ?? s.createdMs)
                    consider(&newestMs, maxTimeCreated(db, table: "message", sessionID: s.id))
                    consider(&newestMs, maxTimeCreated(db, table: "part", sessionID: s.id))
                }
            }
        }
        guard let newestMs else { return nil }
        return Date(timeIntervalSince1970: newestMs / 1000)
    }

    /// Fold `candidate` into `newest`, keeping the larger.
    private static func consider(_ newest: inout Double?, _ candidate: Double?) {
        guard let candidate else { return }
        if let current = newest { newest = max(current, candidate) } else { newest = candidate }
    }

    /// `SELECT MAX(time_created) FROM <table> WHERE session_id = ?`. `table` is a
    /// compile-time constant (`"message"` / `"part"`), never user input, so
    /// interpolating it into the SQL is safe; the session id is a bound parameter.
    private static func maxTimeCreated(_ db: OpaquePointer, table: String, sessionID: String) -> Double? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(time_created) FROM \(table) WHERE session_id = ?", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return columnDouble(stmt, 0)
    }

    // MARK: - Normalize (backfill: one session by id)

    /// Reassemble one session (by id) from `databasePath` into an NDJSON transcript
    /// bounded by `maxBytes`. `nil` when the session is missing/empty or the database
    /// is unreadable.
    public static func normalizeSession(
        databasePath: String, sessionID: String, maxBytes: Int
    ) -> NormalizedTranscript? {
        guard maxBytes > 0 else { return nil }
        var out = Data()
        let (data, truncated) = withDatabase(databasePath) { db -> (Data, Bool) in
            let rows = readSessions(db, whereClause: "id = ?", arg: sessionID)
            return emitSessions(rows, db: db, into: &out, maxBytes: maxBytes)
        } ?? (out, false)
        return TranscriptNormalizer.finalize(data, truncated: truncated)
    }

    // MARK: - Reassembly

    /// Emit each session (header line + its messages, each followed by its parts)
    /// into `out`, honoring the byte cap. Stops — does not continue to the next
    /// session — once the cap is hit, so a truncated transcript never gains a fresh
    /// session header after the cut (CROW-1096 review).
    private static func emitSessions(
        _ rows: [OpenCodeStoreSession], db: OpaquePointer, into out: inout Data, maxBytes: Int
    ) -> (Data, Bool) {
        let newline: UInt8 = 0x0A
        var truncated = false

        /// Append one NDJSON line; false (and truncated) when it would overflow.
        func append(_ line: Data) -> Bool {
            if let last = out.last, last != newline {
                if out.count + 1 > maxBytes { truncated = true; return false }
                out.append(newline)
            }
            if out.count + line.count + 1 > maxBytes { truncated = true; return false }
            out.append(line)
            out.append(newline)
            return true
        }

        sessionLoop: for session in rows {
            if let header = sessionHeaderLine(session), !append(header) { break }
            for message in readMessages(db, sessionID: session.id) {
                if let line = messageLine(message, sessionID: session.id), !append(line) { break sessionLoop }
                for part in readParts(db, messageID: message.id) {
                    if let line = partLine(part, messageID: message.id, sessionID: session.id),
                       !append(line) { break sessionLoop }
                }
            }
        }
        return (out, truncated)
    }

    /// The session row rendered as a compact NDJSON header line.
    private static func sessionHeaderLine(_ s: OpenCodeStoreSession) -> Data? {
        var obj: [String: Any] = ["id": s.id, "type": "session"]
        if let cwd = s.cwd { obj["directory"] = cwd }
        if let parentID = s.parentID { obj["parentID"] = parentID }
        if let title = s.title { obj["title"] = title }
        if let c = s.createdMs { obj["time_created"] = c }
        if let u = s.updatedMs { obj["time_updated"] = u }
        return compactJSON(obj)
    }

    /// A message's stored `data` JSON with its id/sessionID re-attached, compact.
    private static func messageLine(_ m: RawRow, sessionID: String) -> Data? {
        renderRow(m.data, inject: ["id": m.id, "sessionID": sessionID])
    }

    /// A part's stored `data` JSON with its id/messageID/sessionID re-attached.
    private static func partLine(_ p: RawRow, messageID: String, sessionID: String) -> Data? {
        renderRow(p.data, inject: ["id": p.id, "messageID": messageID, "sessionID": sessionID])
    }

    /// Parse a stored `data` JSON string into an object, inject the given keys (only
    /// where absent), and re-serialize compact. Falls back to a bare object of just
    /// the injected keys when `data` is absent or not an object.
    private static func renderRow(_ data: String?, inject: [String: Any]) -> Data? {
        var obj: [String: Any]
        if let data, let parsed = jsonObject(data) {
            obj = parsed
        } else {
            obj = [:]
        }
        for (k, v) in inject where obj[k] == nil { obj[k] = v }
        return compactJSON(obj)
    }

    // MARK: - SQLite access

    /// A raw `(id, data)` row from `message` / `part`.
    private struct RawRow { let id: String; let data: String? }

    /// Open `path` read-only, run `body`, and always close. Returns `nil` when the
    /// database can't be opened (missing file, locked, corrupt) — a best-effort read
    /// never throws into the collector.
    private static func withDatabase<T>(_ path: String, _ body: (OpaquePointer) -> T) -> T? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        // Read-only; a live OpenCode may hold the write lock, so bound the wait.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        return body(db)
    }

    /// Read session rows, optionally filtered by a single-`?` WHERE clause.
    private static func readSessions(
        _ db: OpaquePointer, whereClause: String?, arg: String?
    ) -> [OpenCodeStoreSession] {
        var sql = "SELECT id, directory, parent_id, title, time_created, time_updated FROM session"
        if let whereClause { sql += " WHERE \(whereClause)" }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let arg { sqlite3_bind_text(stmt, 1, arg, -1, SQLITE_TRANSIENT) }

        var out: [OpenCodeStoreSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, 0), !id.isEmpty else { continue }
            out.append(OpenCodeStoreSession(
                id: id,
                cwd: nonEmpty(columnText(stmt, 1)),
                parentID: nonEmpty(columnText(stmt, 2)),
                title: nonEmpty(columnText(stmt, 3)),
                createdMs: columnDouble(stmt, 4),
                updatedMs: columnDouble(stmt, 5)))
        }
        return out
    }

    /// A session's messages in `(time_created, id)` order — the DB's own index order.
    private static func readMessages(_ db: OpaquePointer, sessionID: String) -> [RawRow] {
        query(db,
              "SELECT id, data FROM message WHERE session_id = ? ORDER BY time_created, id",
              arg: sessionID)
    }

    /// A message's parts in `id` order (ascending ids are chronological).
    private static func readParts(_ db: OpaquePointer, messageID: String) -> [RawRow] {
        query(db,
              "SELECT id, data FROM part WHERE message_id = ? ORDER BY id",
              arg: messageID)
    }

    /// Run a two-column `(id, data)` query bound to one text arg.
    private static func query(_ db: OpaquePointer, _ sql: String, arg: String) -> [RawRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, arg, -1, SQLITE_TRANSIENT)
        var out: [RawRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = columnText(stmt, 0), !id.isEmpty else { continue }
            out.append(RawRow(id: id, data: columnText(stmt, 1)))
        }
        return out
    }

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    private static func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    // MARK: - JSON helpers

    private static func jsonObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    private static func compactJSON(_ obj: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

#else

    // Linux: no SQLite module. The daemon that runs the collector is macOS-only, so
    // these are never exercised in production; they exist so `crowd`/`crow` and
    // CrowCore compile on the Linux CI lane (ADR 0007). Behavioral tests are gated
    // to `canImport(SQLite3)` and run on macOS.
    public static func sessions(databasePath: String) -> [OpenCodeStoreSession] { [] }
    public static func cwd(databasePath: String, sessionID: String) -> String? { nil }
    public static func newestActivity(databaseFiles: [URL], cwd: String) -> Date? { nil }
    public static func normalizeSessions(
        databaseFiles: [URL], cwd: String, maxBytes: Int
    ) -> NormalizedTranscript? { nil }
    public static func normalizeSession(
        databasePath: String, sessionID: String, maxBytes: Int
    ) -> NormalizedTranscript? { nil }

#endif
}

#if canImport(SQLite3)
/// `SQLITE_TRANSIENT` tells SQLite to copy the bound text; the Swift import doesn't
/// surface the macro, so re-declare it (the standard pattern for the C API).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif
