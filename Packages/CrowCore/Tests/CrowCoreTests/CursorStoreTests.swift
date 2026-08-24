import Foundation
import Testing
@testable import CrowCore
#if canImport(SQLite3)
import SQLite3
#endif

/// Builds a minimal Cursor `store.db` (+ sibling `meta.json`) the way
/// `cursor-agent` lays one out — content-addressed `blobs`, a `meta['0']`
/// hex-JSON header pointing at a root blob whose repeated protobuf field 1 lists
/// the ordered message-blob ids — so `CursorStore` can be exercised without a real
/// Cursor install (CROW-1095). Shared across the CrowCore test target.
enum CursorStoreFixture {
    #if canImport(SQLite3)
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    #endif

    /// 32 deterministic bytes for a blob id seeded by `n`.
    static func id32(_ n: Int) -> [UInt8] { (0..<32).map { UInt8((n &* 31 &+ $0) & 0xff) } }
    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Write `<dir>/store.db` + `<dir>/meta.json`. `messages` are stored in order;
    /// a non-nil `garbageBlob` is inserted as a raw blob referenced **last** in the
    /// root, to exercise the plaintext-JSON guard. Returns the `store.db` URL.
    @discardableResult
    static func write(
        dir: URL, agentID: String, cwd: String?,
        messages: [String], garbageBlob: [UInt8]? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeDB = dir.appendingPathComponent("store.db")

        // meta.json sibling (carries the cwd for attribution).
        var metaJSON: [String: Any] = ["schemaVersion": 1, "hasConversation": true]
        if let cwd { metaJSON["cwd"] = cwd }
        try JSONSerialization.data(withJSONObject: metaJSON)
            .write(to: dir.appendingPathComponent("meta.json"))

        #if canImport(SQLite3)
        var db: OpaquePointer?
        #expect(sqlite3_open(storeDB.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB);")
        exec(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);")

        var refs: [[UInt8]] = []
        for (i, msg) in messages.enumerated() {
            let id = id32(i + 1)
            insertBlob(db, id: hex(id), data: Data(msg.utf8))
            refs.append(id)
        }
        if let garbageBlob {
            let id = id32(9001)
            insertBlob(db, id: hex(id), data: Data(garbageBlob))
            refs.append(id)
        }

        // Root protobuf: repeated field 1 refs, then a couple of non-field-1
        // fields (a length-delimited field 5 and a varint field 8) to exercise the
        // wire-type skipping — Cursor packs conversation metadata alongside.
        var root = Data()
        for id in refs { root.append(0x0A); root.append(0x20); root.append(contentsOf: id) }
        root.append(contentsOf: [0x2A, 0x03, 0x01, 0x02, 0x03]) // field 5, len 3
        root.append(contentsOf: [0x40, 0x96, 0x01])             // field 8, varint 150
        let rootID = id32(7777)
        insertBlob(db, id: hex(rootID), data: root)

        let meta0: [String: Any] = [
            "agentId": agentID,
            "latestRootBlobId": hex(rootID),
            "blobEncryptionKey": String(repeating: "0", count: 64),
        ]
        let meta0Hex = try JSONSerialization.data(withJSONObject: meta0)
            .map { String(format: "%02x", $0) }.joined()
        insertMeta(db, key: "0", value: meta0Hex)
        #else
        // No SQLite on this platform (the Linux CI runner — SQLite3 is a
        // macOS-SDK module): create the `store.db` FILE as a placeholder so
        // filesystem/scan tests (which only need the filename + sibling meta.json)
        // still run here. The content-level extraction tests are `#if
        // canImport(SQLite3)`-guarded and run on macOS (release.yml), where Crow's
        // daemon — and the Cursor extractor — actually run.
        try Data().write(to: storeDB)
        #endif
        return storeDB
    }

    #if canImport(SQLite3)
    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    private static func insertBlob(_ db: OpaquePointer?, id: String, data: Data) {
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO blobs (id, data) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(data.count), transient)
        }
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
    }
    private static func insertMeta(_ db: OpaquePointer?, key: String, value: String) {
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "INSERT INTO meta (key, value) VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_text(stmt, 2, value, -1, transient)
        #expect(sqlite3_step(stmt) == SQLITE_DONE)
    }
    #endif
}

@Suite struct CursorStoreTests {
    private func tmp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // The SQLite-backed extraction tests run only where `SQLite3` is importable
    // (macOS — release.yml); the Linux CI (`canImport(SQLite3) == false`) skips
    // them, exactly as it skips the Darwin-only CrowTelemetry SQLite tests. The
    // cwd / protobuf / JSON-guard tests below are pure Foundation and run
    // everywhere.
    #if canImport(SQLite3)
    @Test func extractsOrderedMessagesAndDropsNonJSON() throws {
        let base = try tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let messages = [
            #"{"role":"system","content":"sys"}"#,
            #"{"role":"user","content":"hi"}"#,
            #"{"role":"assistant","content":[{"type":"text","text":"yo"}]}"#,
        ]
        // A ciphertext-like trailing blob (invalid UTF-8) must be dropped, not
        // emitted — the guard that keeps a future encrypted build failing closed.
        let db = try CursorStoreFixture.write(
            dir: base.appendingPathComponent("sub"), agentID: "sub", cwd: "/ws/x",
            messages: messages, garbageBlob: [0xff, 0x00, 0x80, 0x01])
        let lines = try #require(CursorStore.messageLines(fromStoreDB: db))
        #expect(lines.count == 3)
        #expect(lines.map { String(data: $0, encoding: .utf8) } == messages)
    }
    #endif

    @Test func recordedCwdReadsSiblingMetaJSON() throws {
        let base = try tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let db = try CursorStoreFixture.write(
            dir: base.appendingPathComponent("s1"), agentID: "s1", cwd: "/ws/y",
            messages: [#"{"role":"user"}"#])
        #expect(CursorStore.recordedCwd(forStoreDB: db) == "/ws/y")

        // A chat with no cwd in its meta.json is unattributable → nil (dropped).
        let db2 = try CursorStoreFixture.write(
            dir: base.appendingPathComponent("s2"), agentID: "s2", cwd: nil,
            messages: [#"{"role":"user"}"#])
        #expect(CursorStore.recordedCwd(forStoreDB: db2) == nil)
        // A missing store/sibling is also nil, never a crash.
        #expect(CursorStore.recordedCwd(forStoreDB: base.appendingPathComponent("nope/store.db")) == nil)
    }

    #if canImport(SQLite3)
    @Test func agentIdFromMetaZero() throws {
        let base = try tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let db = try CursorStoreFixture.write(
            dir: base.appendingPathComponent("SUBID"), agentID: "AGENT-1", cwd: "/w",
            messages: [#"{"role":"user"}"#])
        #expect(CursorStore.agentId(fromStoreDB: db) == "AGENT-1")
    }
    #endif

    @Test func messageRefsSkipsNonFieldOneFields() {
        var root = Data()
        let a = [UInt8](repeating: 0xAB, count: 32)
        let b = [UInt8](repeating: 0xCD, count: 32)
        root.append(0x0A); root.append(0x20); root.append(contentsOf: a)
        root.append(contentsOf: [0x2A, 0x02, 0x09, 0x09]) // field 5, len 2 — skipped
        root.append(0x0A); root.append(0x20); root.append(contentsOf: b)
        root.append(contentsOf: [0x40, 0x96, 0x01])       // field 8 varint — skipped
        #expect(CursorStore.messageRefs(inRoot: root)
            == [String(repeating: "ab", count: 32), String(repeating: "cd", count: 32)])
        // A truncated length prefix stops cleanly rather than reading OOB.
        #expect(CursorStore.messageRefs(inRoot: Data([0x0A, 0x20, 0x01, 0x02])).isEmpty)
    }

    @Test func jsonLineGuardsUTF8AndLeadingOpener() {
        #expect(CursorStore.jsonLine(Data(#"{"a":1}"#.utf8)) != nil)
        #expect(CursorStore.jsonLine(Data(#"[1,2]"#.utf8)) != nil)
        #expect(CursorStore.jsonLine(Data([0xff, 0xfe])) == nil)        // not UTF-8
        #expect(CursorStore.jsonLine(Data("plain text".utf8)) == nil)  // no JSON opener
        // A stray newline inside a blob is collapsed so one blob stays one line.
        let collapsed = CursorStore.jsonLine(Data("{\"a\":\n1}".utf8))
            .flatMap { String(data: $0, encoding: .utf8) }
        #expect(collapsed == "{\"a\": 1}")
    }

    // MARK: TranscriptNormalizer .sqlite

    #if canImport(SQLite3)
    @Test func normalizerSqliteConcatenatesStoresInOrder() throws {
        let base = try tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let db1 = try CursorStoreFixture.write(
            dir: base.appendingPathComponent("s1"), agentID: "s1", cwd: "/w",
            messages: [#"{"role":"system"}"#, #"{"role":"user"}"#])
        let db2 = try CursorStoreFixture.write(
            dir: base.appendingPathComponent("s2"), agentID: "s2", cwd: "/w",
            messages: [#"{"role":"assistant"}"#])

        let t = try #require(TranscriptNormalizer.normalize(
            files: [db1, db2], format: .sqlite, maxBytes: 1_000_000))
        #expect(t.eventCount == 3)
        #expect(t.truncated == false)
        let lines = String(data: t.data, encoding: .utf8)!.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].contains("system"))
        #expect(lines[1].contains("user"))
        #expect(lines[2].contains("assistant"))

        // An unreadable/absent store yields nothing (upload nothing, never garbage).
        #expect(TranscriptNormalizer.normalize(
            files: [base.appendingPathComponent("gone.db")], format: .sqlite, maxBytes: 1000) == nil)
    }

    @Test func normalizerSqliteTruncatesAtWholeLines() throws {
        let base = try tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let messages = (0..<10).map { #"{"role":"user","i":\#($0)}"# }
        let db = try CursorStoreFixture.write(
            dir: base.appendingPathComponent("s"), agentID: "s", cwd: "/w", messages: messages)
        // A cap that admits only a couple of lines: the body is truncated but still
        // parses as clean NDJSON (no partial object).
        let t = try #require(TranscriptNormalizer.normalize(files: [db], format: .sqlite, maxBytes: 60))
        #expect(t.truncated == true)
        let body = String(data: t.data, encoding: .utf8)!
        for line in body.split(separator: "\n") {
            #expect(line.hasPrefix("{") && line.hasSuffix("}"))
        }
    }
    #endif
}
