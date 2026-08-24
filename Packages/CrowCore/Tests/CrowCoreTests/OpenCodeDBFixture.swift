import Foundation

#if canImport(SQLite3)
import SQLite3

/// Builds a temporary `opencode.db` with the subset of OpenCode's current SQLite
/// schema the reader touches (CROW-1096) — for tests that exercise
/// `OpenCodeStore` / the backfill scanner against a real database. Gated to
/// `canImport(SQLite3)` (macOS), matching the reader.
enum OpenCodeDBFixture {
    /// Create a database at `path` with the given `session` / `message` / `part`
    /// rows. A `nil` cwd/parent becomes SQL NULL.
    static func write(
        at path: String,
        sessions: [(id: String, cwd: String?, parentID: String?)],
        messages: [(id: String, sessionID: String, created: Int, data: String)] = [],
        parts: [(id: String, messageID: String, sessionID: String, data: String)] = []
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "OpenCodeDBFixture", code: 1)
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE session(id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, directory TEXT,
                             title TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        """
        try exec(db, schema)

        func q(_ s: String?) -> String { s.map { "'\(sqlEscape($0))'" } ?? "NULL" }
        for s in sessions {
            try exec(db, "INSERT INTO session VALUES('\(s.id)','proj',\(q(s.parentID)),\(q(s.cwd))," +
                         "'t',1000,2000);")
        }
        for m in messages {
            try exec(db, "INSERT INTO message VALUES('\(m.id)','\(m.sessionID)',\(m.created)," +
                         "'\(sqlEscape(m.data))');")
        }
        for p in parts {
            try exec(db, "INSERT INTO part VALUES('\(p.id)','\(p.messageID)','\(p.sessionID)',0," +
                         "'\(sqlEscape(p.data))');")
        }
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "sqlite exec failed"
            sqlite3_free(err)
            throw NSError(domain: "OpenCodeDBFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static func sqlEscape(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }
}
#endif
