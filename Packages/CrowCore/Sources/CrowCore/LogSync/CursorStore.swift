import Foundation
#if canImport(SQLite3)
import SQLite3
#endif

/// Reads the Cursor CLI's per-chat store — `~/.cursor/chats/<chatId>/<subId>/
/// store.db` plus its sibling `meta.json` — into the two shapes the collector and
/// the backfill need (CROW-1095):
///  - the **ordered conversation** as NDJSON message lines, and
///  - the **recorded cwd** used to attribute a globally-stored chat to a worktree.
///
/// On-disk shape (reverse-engineered against `cursor-agent 2026.08.04`):
///  - `store.db` is a SQLite database with two tables — `blobs(id TEXT PRIMARY
///    KEY, data BLOB)` and `meta(key TEXT PRIMARY KEY, value TEXT)`. Blobs are
///    **content-addressed** (`id == sha256(data)`).
///  - `meta['0']` is a hex-encoded JSON object carrying `latestRootBlobId` (the
///    current conversation head) and `agentId` (== the `<subId>` directory name).
///  - The **root blob** is a protobuf whose repeated field 1 (`0x0A 0x20 <32-byte
///    id>`) lists the conversation's message-blob ids **in order**.
///  - Each **message blob** is one compact, single-line JSON object
///    (`{"role":"system|user|assistant|tool","content":…}`) — already the NDJSON
///    line we upload.
///
/// A `blobEncryptionKey` also rides `meta['0']`; today's blobs are plaintext, but
/// this reader is defensive: a message blob that is not valid UTF-8 JSON is
/// dropped, so if a future Cursor build actually encrypts the blobs the extractor
/// yields `nil` (upload nothing) rather than shipping ciphertext (CROW-1095).
///
/// Pure and dependency-free apart from the system `SQLite3` module (no external
/// package), so both the live collector and the backfill route through one
/// extractor and it is unit-testable in CrowCore against a constructed `store.db`.
public enum CursorStore {
    /// The working directory recorded for a chat, read from the **sibling
    /// `meta.json`** next to `storeDB` (`{"…","cwd":"/abs/path"}`). This is the
    /// Cursor attribution signal — unlike Codex, the cwd is not in the transcript
    /// itself, so `AgentLogCwdReader` (a transcript-head reader) does not apply.
    /// Returns `nil` when the sibling is missing/unreadable or carries no cwd — an
    /// unattributable chat is then dropped, never guessed.
    public static func recordedCwd(forStoreDB storeDB: URL) -> String? {
        let metaJSON = storeDB.deletingLastPathComponent()
            .appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaJSON),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwd = obj["cwd"] as? String else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The chat's own session UID — `meta['0'].agentId`, which is also the
    /// `<subId>` directory name. The live path keys uploads on the Crow session
    /// UUID, but the backfill needs the harness's own stable id; the directory
    /// name is authoritative and cheap (no SQLite), so the scanner prefers it and
    /// this reader is the fallback for a direct caller that has only the file.
    public static func agentId(fromStoreDB storeDB: URL) -> String? {
        #if canImport(SQLite3)
        return withDatabase(storeDB) { db in
            guard let metaObj = metaZero(db) else { return nil }
            let id = (metaObj["agentId"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (id?.isEmpty == false) ? id : nil
        } ?? nil
        #else
        return nil
        #endif
    }

    /// The chat's messages as ordered NDJSON lines (each an already-compact JSON
    /// object), or `nil` when the store can't be opened, has no conversation, or
    /// none of its message blobs are plaintext JSON. Each returned `Data` is one
    /// line with no trailing newline; the caller joins them.
    public static func messageLines(fromStoreDB storeDB: URL) -> [Data]? {
        #if canImport(SQLite3)
        return withDatabase(storeDB) { db -> [Data]? in
            guard let metaObj = metaZero(db),
                  let rootId = (metaObj["latestRootBlobId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rootId.isEmpty,
                  let rootBlob = blob(db, id: rootId) else { return nil }

            let refs = messageRefs(inRoot: rootBlob)
            guard !refs.isEmpty else { return nil }

            var lines: [Data] = []
            lines.reserveCapacity(refs.count)
            for ref in refs {
                guard let data = blob(db, id: ref), let line = jsonLine(data) else { continue }
                lines.append(line)
            }
            return lines.isEmpty ? nil : lines
        } ?? nil
        #else
        return nil
        #endif
    }

    // MARK: - Blob-graph parsing (pure, platform-independent)

    /// The ordered message-blob ids listed in a root blob's repeated protobuf
    /// field 1. Other fields (conversation metadata Cursor also packs into the
    /// root) are skipped by wire type, so only the message refs — in their encoded
    /// order, which is conversation order — are returned. Each id is the lowercase
    /// hex of the 32-byte reference, matching the `blobs.id` text column.
    static func messageRefs(inRoot data: Data) -> [String] {
        let bytes = [UInt8](data)
        var i = 0
        var refs: [String] = []

        func readVarint() -> UInt64? {
            var shift: UInt64 = 0
            var result: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        while i < bytes.count {
            guard let tag = readVarint() else { break }
            let field = tag >> 3
            let wire = tag & 7
            switch wire {
            case 0: // varint
                if readVarint() == nil { return refs }
            case 1: // 64-bit
                i += 8
            case 5: // 32-bit
                i += 4
            case 2: // length-delimited
                guard let len = readVarint() else { return refs }
                let n = Int(len)
                guard n >= 0, i + n <= bytes.count else { return refs }
                if field == 1 {
                    refs.append(bytes[i..<(i + n)].map { String(format: "%02x", $0) }.joined())
                }
                i += n
            default: // 3/4 (groups, deprecated) or anything unexpected — stop cleanly
                return refs
            }
        }
        return refs
    }

    /// A message blob → one NDJSON line, or `nil` if it isn't plaintext UTF-8 JSON
    /// (an object/array). The UTF-8 + leading-`{`/`[` guard is what makes a future
    /// encrypted build fail closed: ciphertext is almost never valid UTF-8, and if
    /// it were, it would not lead with a JSON opener. Any stray CR/LF inside the
    /// blob is stripped so one blob stays one NDJSON line.
    static func jsonLine(_ data: Data) -> Data? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.data(using: .utf8)
    }

    // MARK: - SQLite access

    #if canImport(SQLite3)
    /// SQLite wants a copy of a bound string (the default would keep a dangling
    /// pointer once the Swift `String` is freed).
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Open `storeDB` **read-only** (never mutate a user's chat store, and never
    /// take a write lock on a DB `cursor-agent` may still hold) and run `body`.
    /// A quiescent store — the only kind the collector uploads, gated by the quiet
    /// period — opens cleanly; a store whose `-wal`/`-shm` a crash left in a state
    /// a read-only connection can't attach to simply yields `nil` (best-effort).
    private static func withDatabase<T>(_ storeDB: URL, _ body: (OpaquePointer) -> T) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        return body(db)
    }

    /// Decode the hex-encoded JSON at `meta['0']` into its object, or `nil`.
    private static func metaZero(_ db: OpaquePointer) -> [String: Any]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='0'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        let hex = String(cString: c)
        guard let json = Data(hexEncoded: hex),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        return obj
    }

    /// The `data` BLOB for a content id, or `nil` when absent.
    private static func blob(_ db: OpaquePointer, id: String) -> Data? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT data FROM blobs WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let ptr = sqlite3_column_blob(stmt, 0) else {
            // A zero-length blob reports a nil pointer but is still a valid row.
            return sqlite3_column_bytes(stmt, 0) == 0 ? Data() : nil
        }
        let n = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: ptr, count: n)
    }
    #endif
}

private extension Data {
    /// Decode a hex string (even length, `[0-9a-fA-F]`) into bytes, or `nil`.
    init?(hexEncoded hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30          // 0-9
            case 0x61...0x66: return c - 0x61 + 10     // a-f
            case 0x41...0x46: return c - 0x41 + 10     // A-F
            default: return nil
            }
        }
        var idx = 0
        while idx < chars.count {
            guard let hi = nibble(chars[idx]), let lo = nibble(chars[idx + 1]) else { return nil }
            out.append(hi << 4 | lo)
            idx += 2
        }
        self = Data(out)
    }
}
