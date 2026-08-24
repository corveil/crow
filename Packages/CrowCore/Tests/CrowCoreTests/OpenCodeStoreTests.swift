import Foundation
import Testing
@testable import CrowCore

#if canImport(SQLite3)
import SQLite3

/// Behavioral tests for the OpenCode `opencode.db` reader (CROW-1096). Gated to
/// `canImport(SQLite3)` — the reader is macOS-only (the Crow daemon that runs the
/// collector is macOS; Linux CI compiles a no-op stub), so these run on macOS.
@Suite struct OpenCodeStoreTests {
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Build a temp `opencode.db` with the current OpenCode schema (the columns the
    /// reader uses) and return its path plus a cleanup.
    private func makeDB() throws -> (path: String, insert: (String) -> Void, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("opencode.db").path

        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        let schema = """
        CREATE TABLE session(id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, directory TEXT,
                             title TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
        CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
        """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        let handle = db
        let exec: (String) -> Void = { sql in _ = sqlite3_exec(handle, sql, nil, nil, nil) }
        return (path, exec, { sqlite3_close(handle); try? FileManager.default.removeItem(at: dir) })
    }

    /// Insert a session row. A `nil` directory/parent becomes SQL NULL.
    private func session(
        _ insert: (String) -> Void, id: String, directory: String?,
        parentID: String? = nil, title: String = "t", created: Int = 1000, updated: Int = 2000
    ) {
        func q(_ s: String?) -> String { s.map { "'\($0)'" } ?? "NULL" }
        insert("INSERT INTO session VALUES('\(id)','proj',\(q(parentID)),\(q(directory))," +
               "'\(title)',\(created),\(updated));")
    }

    private func message(_ insert: (String) -> Void, id: String, sessionID: String, created: Int, data: String) {
        insert("INSERT INTO message VALUES('\(id)','\(sessionID)',\(created),'\(data)');")
    }

    private func part(_ insert: (String) -> Void, id: String, messageID: String, sessionID: String, data: String, created: Int = 0) {
        insert("INSERT INTO part VALUES('\(id)','\(messageID)','\(sessionID)',\(created),'\(data)');")
    }

    private func lineIDs(_ data: Data) -> [String] {
        String(data: data, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> String? in
                guard let d = line.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
                else { return nil }
                return o["id"] as? String
            }
    }

    @Test func sessionsReadsRowsWithCwdAndParent() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_A", directory: "/dev/ws/repo-1", title: "Fix it")
        session(insert, id: "ses_child", directory: "/dev/ws/repo-1", parentID: "ses_A")

        let rows = OpenCodeStore.sessions(databasePath: path)
        #expect(rows.count == 2)
        let a = try #require(rows.first { $0.id == "ses_A" })
        #expect(a.cwd == "/dev/ws/repo-1")
        #expect(a.title == "Fix it")
        #expect(a.isChild == false)
        let child = try #require(rows.first { $0.id == "ses_child" })
        #expect(child.parentID == "ses_A")
        #expect(child.isChild == true)
    }

    @Test func cwdProbeDropsChildAndMissingDirectory() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_top", directory: "/dev/ws/repo-1")
        session(insert, id: "ses_kid", directory: "/dev/ws/repo-1", parentID: "ses_top")
        session(insert, id: "ses_nodir", directory: nil)

        #expect(OpenCodeStore.cwd(databasePath: path, sessionID: "ses_top") == "/dev/ws/repo-1")
        #expect(OpenCodeStore.cwd(databasePath: path, sessionID: "ses_kid") == nil)   // child dropped
        #expect(OpenCodeStore.cwd(databasePath: path, sessionID: "ses_nodir") == nil) // no directory
        #expect(OpenCodeStore.cwd(databasePath: path, sessionID: "ses_missing") == nil)
    }

    @Test func normalizeSessionOrdersHeaderMessagesParts() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_C", directory: "/dev/ws/repo-1")
        // Two messages; time_created ascending. Parts sort by id.
        message(insert, id: "msg_b001", sessionID: "ses_C", created: 10, data: #"{\"role\":\"user\"}"#)
        part(insert, id: "prt_b001a", messageID: "msg_b001", sessionID: "ses_C", data: #"{\"type\":\"text\"}"#)
        message(insert, id: "msg_b002", sessionID: "ses_C", created: 20, data: #"{\"role\":\"assistant\"}"#)
        part(insert, id: "prt_b002a", messageID: "msg_b002", sessionID: "ses_C", data: #"{\"type\":\"text\"}"#)
        part(insert, id: "prt_b002b", messageID: "msg_b002", sessionID: "ses_C", data: #"{\"type\":\"tool\"}"#)

        let t = try #require(OpenCodeStore.normalizeSession(databasePath: path, sessionID: "ses_C", maxBytes: 1 << 20))
        #expect(lineIDs(t.data) == ["ses_C", "msg_b001", "prt_b001a", "msg_b002", "prt_b002a", "prt_b002b"])
        let text = String(data: t.data, encoding: .utf8)!
        #expect(text.hasSuffix("\n"))
        for line in text.split(separator: "\n") {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
    }

    @Test func normalizeSessionsSelectsByCwdAndExcludesChildren() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_mine", directory: "/dev/ws/repo-1096", created: 100)
        message(insert, id: "msg_m", sessionID: "ses_mine", created: 1, data: #"{\"role\":\"user\"}"#)
        session(insert, id: "ses_other", directory: "/dev/ws/repo-999", created: 200)
        message(insert, id: "msg_o", sessionID: "ses_other", created: 1, data: #"{\"role\":\"user\"}"#)
        session(insert, id: "ses_child", directory: "/dev/ws/repo-1096", parentID: "ses_mine", created: 150)

        let t = try #require(OpenCodeStore.normalizeSessions(
            databaseFiles: [URL(fileURLWithPath: path)], cwd: "/dev/ws/repo-1096", maxBytes: 1 << 20))
        let ids = lineIDs(t.data)
        #expect(ids.contains("ses_mine"))
        #expect(!ids.contains("ses_other"))  // different cwd
        #expect(!ids.contains("ses_child"))  // child excluded
    }

    @Test func normalizeSessionsConcatenatesMultipleMatchesChronologically() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        // Two top-level sessions in the SAME worktree — a Crow session spanning two
        // `opencode` invocations. Concatenated oldest-first.
        session(insert, id: "ses_first", directory: "/w/r-1", created: 100)
        message(insert, id: "msg_1", sessionID: "ses_first", created: 1, data: #"{\"role\":\"user\"}"#)
        session(insert, id: "ses_second", directory: "/w/r-1", created: 200)
        message(insert, id: "msg_2", sessionID: "ses_second", created: 1, data: #"{\"role\":\"user\"}"#)

        let t = try #require(OpenCodeStore.normalizeSessions(
            databaseFiles: [URL(fileURLWithPath: path)], cwd: "/w/r-1", maxBytes: 1 << 20))
        let ids = lineIDs(t.data)
        #expect(ids.firstIndex(of: "ses_first")! < ids.firstIndex(of: "ses_second")!)
    }

    @Test func truncationStopsAndDoesNotStartNextSession() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_1", directory: "/w/r-1", created: 100)
        message(insert, id: "msg_big", sessionID: "ses_1", created: 1,
                data: "{\\\"x\\\":\\\"\(String(repeating: "y", count: 400))\\\"}")
        session(insert, id: "ses_2", directory: "/w/r-1", created: 200)
        message(insert, id: "msg_2", sessionID: "ses_2", created: 1, data: #"{\"role\":\"user\"}"#)

        // A cap that admits ses_1's header (~90 B) but not its ~430 B message —
        // must NOT then append ses_2's header after the cut (CROW-1096 review Yellow).
        let t = try #require(OpenCodeStore.normalizeSessions(
            databaseFiles: [URL(fileURLWithPath: path)], cwd: "/w/r-1", maxBytes: 200))
        #expect(t.truncated == true)
        let ids = lineIDs(t.data)
        #expect(!ids.contains("ses_2"))
        for line in String(data: t.data, encoding: .utf8)!.split(separator: "\n") {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
    }

    @Test func missingDatabaseYieldsNothing() {
        #expect(OpenCodeStore.sessions(databasePath: "/no/such/opencode.db").isEmpty)
        #expect(OpenCodeStore.normalizeSession(databasePath: "/no/such.db", sessionID: "x", maxBytes: 1000) == nil)
        #expect(OpenCodeStore.normalizeSessions(
            databaseFiles: [URL(fileURLWithPath: "/no/such.db")], cwd: "/w", maxBytes: 1000) == nil)
    }

    // MARK: newestActivity (quiescence signal — CROW-1096 review)

    private func date(_ ms: Int) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    @Test func newestActivityTakesTheLatestWriteAcrossSessionMessagePart() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_A", directory: "/w/r-1", created: 1_000, updated: 2_000)
        message(insert, id: "msg_a", sessionID: "ses_A", created: 5_000, data: #"{\"role\":\"user\"}"#)
        // A part written after the message — the newest write of all.
        part(insert, id: "prt_a", messageID: "msg_a", sessionID: "ses_A", data: #"{\"type\":\"text\"}"#, created: 9_000)

        let newest = try #require(OpenCodeStore.newestActivity(
            databaseFiles: [URL(fileURLWithPath: path)], cwd: "/w/r-1"))
        #expect(newest == date(9_000))
    }

    @Test func newestActivityMovesWithMessagesEvenWhenSessionRowIsStale() throws {
        // The WAL robustness case: session.time_updated is old, but a new message
        // means the session is still active — the signal must reflect that so the
        // quiet-period gate doesn't upload a premature, write-once snapshot.
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_A", directory: "/w/r-1", created: 1_000, updated: 1_000)
        message(insert, id: "msg_new", sessionID: "ses_A", created: 8_000, data: #"{\"role\":\"assistant\"}"#)

        let newest = try #require(OpenCodeStore.newestActivity(
            databaseFiles: [URL(fileURLWithPath: path)], cwd: "/w/r-1"))
        #expect(newest == date(8_000)) // the message, not the stale session row
    }

    @Test func newestActivityIsScopedToTheWorktreeCwd() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_mine", directory: "/w/r-1", created: 1_000, updated: 2_000)
        message(insert, id: "msg_mine", sessionID: "ses_mine", created: 3_000, data: #"{\"role\":\"user\"}"#)
        // A different worktree churning in the same shared DB must not count.
        session(insert, id: "ses_other", directory: "/w/r-999", created: 1_000, updated: 2_000)
        message(insert, id: "msg_other", sessionID: "ses_other", created: 99_000, data: #"{\"role\":\"user\"}"#)
        // A child of mine also doesn't count.
        session(insert, id: "ses_kid", directory: "/w/r-1", parentID: "ses_mine", created: 1_000, updated: 50_000)

        let newest = try #require(OpenCodeStore.newestActivity(
            databaseFiles: [URL(fileURLWithPath: path)], cwd: "/w/r-1"))
        #expect(newest == date(3_000)) // only ses_mine's own writes, not the other worktree or the child
    }

    @Test func newestActivityNilWhenNothingMatches() throws {
        let (path, insert, cleanup) = try makeDB(); defer { cleanup() }
        session(insert, id: "ses_other", directory: "/w/r-999", created: 1_000, updated: 2_000)
        #expect(OpenCodeStore.newestActivity(
            databaseFiles: [URL(fileURLWithPath: path)], cwd: "/w/r-1") == nil)
        // Missing database → nil.
        #expect(OpenCodeStore.newestActivity(
            databaseFiles: [URL(fileURLWithPath: "/no/such.db")], cwd: "/w/r-1") == nil)
    }
}
#endif
