import Foundation
import Testing
import CrowCore
@testable import CrowDaemon

@Suite struct LogSyncCollectorTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logsync-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Reference resolution (op:// vs plaintext)

    @Test func resolvesPlaintextRefLiterally() {
        #expect(LogSyncCollector.resolveRef("sk-citadel-abc", resolveSecret: { _ in nil }) == "sk-citadel-abc")
    }

    @Test func resolvesOpReference() {
        let key = LogSyncCollector.resolveRef("op://vault/corveil/key") { $0 == "op://vault/corveil/key" ? "RESOLVED" : nil }
        #expect(key == "RESOLVED")
    }

    @Test func blankOrUnresolvableRefIsNil() {
        #expect(LogSyncCollector.resolveRef("   ", resolveSecret: { _ in nil }) == nil)
        #expect(LogSyncCollector.resolveRef("op://missing", resolveSecret: { _ in nil }) == nil)
    }

    // MARK: Upload destination + credential come ONLY from the gateway (CROW-1070)

    /// An opted-in Corveil-upload workspace. The upload destination and the
    /// credential come only from the workspace's own **local-only** `gateway`;
    /// no browser-writable field on `WorkspaceInfo` can supply or redirect them.
    private func corveilWorkspace(gateway: WorkspaceGateway?) -> WorkspaceInfo {
        WorkspaceInfo(name: "Corveil", uploadSessionLogs: true, gateway: gateway)
    }

    @Test func resolvedUploadComesFromTheGateway() {
        let gw = WorkspaceGateway(
            baseURL: "https://corveil.io",
            customHeaders: ["x-citadel-api-key": "Bearer sk-real"])
        let upload = LogSyncCollector.resolvedUpload(
            for: corveilWorkspace(gateway: gw), resolveSecret: { _ in nil })
        #expect(upload?.baseURL == "https://corveil.io")
        #expect(upload?.apiKey == "sk-real") // Bearer stripped for the uploader to re-wrap
    }

    @Test func noGatewayResolvesToNil() {
        // THE security invariant: the local-only gateway is the sole source of an
        // upload destination. With no gateway to reuse, `resolvedUpload` is nil and
        // nothing uploads — a browser-writable workspace field alone can never
        // supply a credential-bearing destination.
        #expect(LogSyncCollector.resolvedUpload(
            for: corveilWorkspace(gateway: nil), resolveSecret: { _ in nil }) == nil)
    }

    @Test func emptyGatewayOrMissingKeyResolvesToNil() {
        // An empty gateway has nothing to reuse.
        #expect(LogSyncCollector.resolvedUpload(
            for: corveilWorkspace(gateway: WorkspaceGateway(baseURL: "", customHeaders: [:])),
            resolveSecret: { _ in nil }) == nil)
        // A gateway with a base URL but no recognizable Corveil key can't authenticate.
        let noKey = WorkspaceGateway(baseURL: "https://corveil.io", customHeaders: ["X-Other": "v"])
        #expect(LogSyncCollector.resolvedUpload(
            for: corveilWorkspace(gateway: noKey), resolveSecret: { _ in nil }) == nil)
    }

    // MARK: Gateway credential reuse (CROW-1066)

    @Test func stripBearerRemovesSchemeCaseInsensitively() {
        #expect(LogSyncCollector.stripBearer("Bearer sk-1") == "sk-1")
        #expect(LogSyncCollector.stripBearer("bearer sk-2") == "sk-2")
        #expect(LogSyncCollector.stripBearer("  Bearer   sk-3 ") == "sk-3")
        // No scheme — returned trimmed but otherwise untouched.
        #expect(LogSyncCollector.stripBearer("sk-4") == "sk-4")
        // "bearerish" is not the scheme (no space) — left alone.
        #expect(LogSyncCollector.stripBearer("bearerish") == "bearerish")
    }

    @Test func corveilAPIKeyFromCitadelHeaderStripsBearer() {
        let gw = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["x-citadel-api-key": "Bearer sk-citadel-abc"])
        #expect(LogSyncCollector.corveilAPIKey(from: gw, resolveSecret: { _ in nil }) == "sk-citadel-abc")
    }

    @Test func corveilAPIKeyResolvesOpReferenceHeader() {
        let gw = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["X-Citadel-Api-Key": "op://Vault/Citadel/key"])
        let key = LogSyncCollector.corveilAPIKey(from: gw) { $0 == "op://Vault/Citadel/key" ? "Bearer sk-resolved" : nil }
        #expect(key == "sk-resolved") // header name matched case-insensitively; op resolved; Bearer stripped
    }

    @Test func corveilAPIKeyPrefersCitadelOverGenericHeaders() {
        let gw = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["authorization": "Bearer generic", "x-citadel-api-key": "Bearer citadel"])
        #expect(LogSyncCollector.corveilAPIKey(from: gw, resolveSecret: { _ in nil }) == "citadel")
    }

    @Test func corveilAPIKeyFallsBackToAuthorizationHeader() {
        let gw = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["Authorization": "Bearer sk-auth"])
        #expect(LogSyncCollector.corveilAPIKey(from: gw, resolveSecret: { _ in nil }) == "sk-auth")
    }

    @Test func corveilAPIKeyNilWhenNoKnownHeader() {
        let gw = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["X-Some-Other": "value"])
        #expect(LogSyncCollector.corveilAPIKey(from: gw, resolveSecret: { _ in nil }) == nil)
        // Unresolvable op:// reference in the credential header ⇒ nil, not a broken key.
        let gw2 = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["x-citadel-api-key": "op://missing"])
        #expect(LogSyncCollector.corveilAPIKey(from: gw2, resolveSecret: { _ in nil }) == nil)
    }

    // MARK: File resolution

    @Test func resolveFilesForDirectorySortsByMtimeAndFiltersExtension() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jsonl")
        let b = dir.appendingPathComponent("b.jsonl")
        let other = dir.appendingPathComponent("notes.txt")
        try "1".write(to: a, atomically: true, encoding: .utf8)
        try "2".write(to: b, atomically: true, encoding: .utf8)
        try "x".write(to: other, atomically: true, encoding: .utf8)
        // Make `a` older than `b`.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: a.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000)], ofItemAtPath: b.path)

        let source = AgentLogSource.directory(dir.path, format: .jsonl, fileExtension: "jsonl")
        let files = LogSyncCollector.resolveFiles(source)
        #expect(files.map(\.lastPathComponent) == ["a.jsonl", "b.jsonl"]) // oldest first, .txt excluded
    }

    @Test func resolveFilesForSpecificFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("x.jsonl")
        try "1".write(to: f, atomically: true, encoding: .utf8)
        #expect(LogSyncCollector.resolveFiles(.file(f.path, format: .jsonl)).count == 1)
        // A directory passed as a .file source resolves to nothing.
        #expect(LogSyncCollector.resolveFiles(.file(dir.path, format: .jsonl)).isEmpty)
        // A missing file resolves to nothing.
        #expect(LogSyncCollector.resolveFiles(.file(dir.appendingPathComponent("nope").path, format: .jsonl)).isEmpty)
    }

    @Test func agentSessionIDOnlyForSingleFile() {
        let one = [URL(fileURLWithPath: "/x/834fd01d.jsonl")]
        #expect(LogSyncCollector.agentSessionID(from: one) == "834fd01d")
        let many = [URL(fileURLWithPath: "/x/a.jsonl"), URL(fileURLWithPath: "/x/b.jsonl")]
        #expect(LogSyncCollector.agentSessionID(from: many) == nil)
        #expect(LogSyncCollector.agentSessionID(from: []) == nil)
    }

    // MARK: cwd-filtered resolution (CROW-1089 — Codex global store)

    /// A recursive, cwd-filtered directory source (the Codex shape) keeps only the
    /// rollouts whose recorded `cwd` matches the worktree, across the date tree.
    @Test func resolveFilesAppliesCwdFilterRecursively() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = dir.appendingPathComponent("2026/08/19", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        func rollout(_ name: String, cwd: String?) throws -> URL {
            let url = day.appendingPathComponent(name)
            let head = cwd.map {
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\",\"cwd\":\"\($0)\"}}\n"
            } ?? "{\"type\":\"session_meta\",\"payload\":{\"id\":\"x\"}}\n"
            try head.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let mine = try rollout("rollout-mine.jsonl", cwd: "/dev/ws/repo-1089")
        _ = try rollout("rollout-other.jsonl", cwd: "/dev/ws/repo-999")
        _ = try rollout("rollout-nocwd.jsonl", cwd: nil) // unattributable → dropped
        // A non-rollout `.jsonl` with a matching cwd must still be excluded by the
        // `rollout-` name prefix — keeps the live path in lockstep with backfill
        // (CROW-1089), even if Codex ever drops other jsonl beside its rollouts.
        _ = try rollout("history.jsonl", cwd: "/dev/ws/repo-1089")

        let source = AgentLogSource.directory(
            dir.path, format: .logDir, fileExtension: "jsonl",
            fileNamePrefix: "rollout-", recursive: true, cwdFilter: "/dev/ws/repo-1089")
        let files = LogSyncCollector.resolveFiles(source)
        #expect(files.map(\.lastPathComponent) == [mine.lastPathComponent])
    }

    @Test func applyingCwdFilterDropsUnattributableAndNoOpsWhenNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jsonl")
        try "{\"cwd\":\"/dev/ws/repo-1\"}\n".write(to: a, atomically: true, encoding: .utf8)
        let b = dir.appendingPathComponent("b.jsonl")
        try "{\"type\":\"x\"}\n".write(to: b, atomically: true, encoding: .utf8) // no cwd

        // nil filter is a no-op (Claude path): both survive.
        #expect(LogSyncCollector.applyingCwdFilter([a, b], nil).count == 2)
        // A concrete filter keeps only the match; the cwd-less file is dropped.
        let kept = LogSyncCollector.applyingCwdFilter([a, b], "/dev/ws/repo-1")
        #expect(kept.map(\.lastPathComponent) == ["a.jsonl"])
        // A blank filter matches nothing (never "match everything").
        #expect(LogSyncCollector.applyingCwdFilter([a, b], "   ").isEmpty)
    }

    // MARK: cwd-filtered resolution — Cursor sqlite store (CROW-1095)

    /// A Cursor `.sqlite` source reads the cwd from the **sibling `meta.json`**
    /// (via `CursorStore.recordedCwd`), not the transcript head, so the filter and
    /// `resolveFiles` both keep only the store.db whose chat ran in this worktree,
    /// and the `-wal`/`-shm` siblings never leak in.
    @Test func resolveFilesSqliteKeepsCwdMatchingStoreDBs() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        func chat(_ name: String, cwd: String?) throws -> URL {
            let sub = dir.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let db = sub.appendingPathComponent("store.db")
            try Data("x".utf8).write(to: db)
            // Siblings that must be excluded by the `db` extension filter.
            try Data("w".utf8).write(to: sub.appendingPathComponent("store.db-wal"))
            try Data("s".utf8).write(to: sub.appendingPathComponent("store.db-shm"))
            if let cwd {
                try #"{"cwd":"\#(cwd)"}"#.write(
                    to: sub.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
            }
            return db
        }
        let mine = try chat("chatA/s1", cwd: "/dev/ws/repo-1095")
        _ = try chat("chatB/s2", cwd: "/dev/ws/repo-999")   // other worktree
        _ = try chat("chatC/s3", cwd: nil)                  // no cwd → unattributable

        let source = AgentLogSource.directory(
            dir.path, format: .sqlite, fileExtension: "db",
            recursive: true, cwdFilter: "/dev/ws/repo-1095")
        // Exactly the one matching store.db — the -wal/-shm siblings, the other
        // worktree's chat, and the unattributable chat are all excluded. Compare by
        // suffix so the enumerator's `/private/var` symlink resolution doesn't
        // spuriously differ from `mine`'s `/var` path.
        let resolved = LogSyncCollector.resolveFiles(source)
        #expect(resolved.count == 1)
        #expect(resolved.first?.lastPathComponent == "store.db")
        #expect(resolved.first?.path.hasSuffix("chatA/s1/store.db") == true)
        #expect(mine.lastPathComponent == "store.db")

        // recordedCwd dispatches on format: `.sqlite` → sibling meta.json.
        #expect(LogSyncCollector.recordedCwd(of: mine, format: .sqlite) == "/dev/ws/repo-1095")
        let noMeta = dir.appendingPathComponent("chatC/s3/store.db")
        #expect(LogSyncCollector.recordedCwd(of: noMeta, format: .sqlite) == nil)
    }

    /// `agentSessionID` for a single Cursor store is the parent `<subId>` dir (the
    /// chat's agentId), since the file stem "store" identifies nothing.
    @Test func agentSessionIDForCursorStoreIsParentDir() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("chatA/SUBID-9", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let db = sub.appendingPathComponent("store.db")
        try Data("x".utf8).write(to: db)
        #expect(LogSyncCollector.agentSessionID(from: [db]) == "SUBID-9")
    }

    /// The quiet-period `newestModification` must see a SQLite `-wal`/`-shm`
    /// sibling's mtime, so a Cursor chat still committing to its WAL (while the
    /// main `store.db` mtime is stale) is not read as quiescent and uploaded
    /// partial (CROW-1095). A non-SQLite file with no siblings is unaffected.
    @Test func newestModificationIncludesWalShmSiblings() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("store.db")
        try Data("x".utf8).write(to: db)
        let wal = dir.appendingPathComponent("store.db-wal")
        try Data("w".utf8).write(to: wal)

        // store.db is old; the WAL is fresh (an active commit).
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: db.path)
        let walTime = Date(timeIntervalSince1970: 9000)
        try FileManager.default.setAttributes(
            [.modificationDate: walTime], ofItemAtPath: wal.path)

        // The newest reflects the WAL, not the stale main file.
        #expect(LogSyncCollector.newestModification([db]) == walTime)

        // A plain file with no WAL/SHM siblings is just its own mtime.
        let plain = dir.appendingPathComponent("a.jsonl")
        try Data("j".utf8).write(to: plain)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: plain.path)
        #expect(LogSyncCollector.newestModification([plain]) == Date(timeIntervalSince1970: 1000))
    }
    // MARK: OpenCode SQLite store (CROW-1096)

    /// An `.openCodeStore` source is the single `opencode.db` file; it resolves to
    /// that file (existence check), and cwd attribution happens by row inside
    /// `OpenCodeStore`, not by dropping files. The `cwdFilter` is carried but not
    /// applied at the file level.
    @Test func resolveFilesReturnsTheOpenCodeDatabaseFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("opencode.db")
        try Data([0x1, 0x2]).write(to: db)
        let source = AgentLogSource(
            path: db.path, selector: .file, format: .openCodeStore, cwdFilter: "/w/r-1")
        #expect(LogSyncCollector.resolveFiles(source).map(\.lastPathComponent) == ["opencode.db"])
        // A missing database resolves to nothing.
        let missing = AgentLogSource(
            path: dir.appendingPathComponent("nope.db").path, selector: .file,
            format: .openCodeStore, cwdFilter: "/w/r-1")
        #expect(LogSyncCollector.resolveFiles(missing).isEmpty)
    }

#if canImport(SQLite3)
    /// End-to-end of the OpenCode read path the collector uses: build a real
    /// `opencode.db`, then normalize by cwd exactly as `sweep` does — only the
    /// top-level, cwd-matching session's rows appear.
    @Test func openCodeNormalizeByCwdSelectsTopLevelMatches() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = dir.appendingPathComponent("opencode.db")
        try OpenCodeDBFixture.write(
            at: db.path,
            sessions: [
                (id: "ses_mine", cwd: "/w/repo-1096", parentID: nil),
                (id: "ses_other", cwd: "/w/repo-999", parentID: nil),
                (id: "ses_kid", cwd: "/w/repo-1096", parentID: "ses_mine"),
            ],
            messages: [
                (id: "msg_a", sessionID: "ses_mine", created: 1, data: #"{"role":"user"}"#),
                (id: "msg_b", sessionID: "ses_other", created: 1, data: #"{"role":"user"}"#),
                (id: "msg_c", sessionID: "ses_kid", created: 1, data: #"{"role":"user"}"#),
            ])

        let t = try #require(OpenCodeStore.normalizeSessions(
            databaseFiles: [db], cwd: "/w/repo-1096", maxBytes: 1 << 20))
        let text = String(data: t.data, encoding: .utf8)!
        #expect(text.contains("ses_mine"))
        #expect(!text.contains("ses_other")) // different cwd
        #expect(!text.contains("ses_kid"))   // child excluded
    }
#endif

    // MARK: Muse shape — session-prefix + subagent exclusion + cwd filter (CROW-1106)

    /// The Muse source (recursive, `session`-prefixed, `subagent`-excluded,
    /// cwd-filtered) keeps only the top-level `session.jsonl` whose recorded
    /// `workspace_root` matches — dropping the nested subagent child (a different
    /// session) and a non-matching sibling.
    @Test func resolveFilesForMuseExcludesSubagentAndFiltersByWorkspaceRoot() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let want = "/dev/ws/crow-1106"

        func journal(_ relPath: String, workspaceRoot: String?) throws -> URL {
            let url = dir.appendingPathComponent(relPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let head = workspaceRoot.map {
                "{\"type\":\"runtime.session.metadata\",\"payload\":{\"record\":{\"workspace_root\":\"\($0)\"}}}\n"
            } ?? "{\"type\":\"runtime.session.metadata\",\"payload\":{\"record\":{}}}\n"
            try head.write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        _ = try journal("2026/08/24/ID-1/session.jsonl", workspaceRoot: want)
        // Nested subagent child — matching cwd, but excluded by path component.
        _ = try journal("2026/08/24/ID-1/subagent/CHILD/session.jsonl", workspaceRoot: want)
        // A different worktree's session — dropped by the cwd filter.
        _ = try journal("2026/08/24/ID-2/session.jsonl", workspaceRoot: "/dev/ws/other")

        let source = AgentLogSource.directory(
            dir.path, format: .logDir, fileExtension: "jsonl",
            fileNamePrefix: "session", recursive: true,
            excludePathComponents: ["subagent"], cwdFilter: want)
        let files = LogSyncCollector.resolveFiles(source)
        // Only the top-level, cwd-matching journal — asserted by path suffix so the
        // macOS `/var` → `/private/var` symlink doesn't fail a raw-URL compare.
        #expect(files.count == 1)
        let got = files.first?.path ?? ""
        #expect(got.hasSuffix("/ID-1/session.jsonl"), "got: \(got)")
        #expect(!got.contains("subagent")) // child session excluded
        #expect(!got.contains("ID-2"))     // non-matching cwd dropped
    }

    // MARK: Result → ledger mapping

    @Test func ledgerEntryMapping() {
        #expect(LogSyncCollector.ledgerEntry(for: .created, sha: "s", size: 1, at: 0).status == .uploaded)
        #expect(LogSyncCollector.ledgerEntry(for: .alreadyExists, sha: "s", size: 1, at: 0).status == .uploaded)

        let big = LogSyncCollector.ledgerEntry(for: .tooLarge, sha: "s", size: 1, at: 0)
        #expect(big.status == .skippedPermanent)
        #expect(big.reason == "too_large")

        let bad = LogSyncCollector.ledgerEntry(for: .rejected(status: 404), sha: "s", size: 1, at: 0)
        #expect(bad.status == .skippedPermanent)
        #expect(bad.reason == "rejected_404")

        #expect(LogSyncCollector.ledgerEntry(for: .transient, sha: "s", size: 1, at: 0).status == .failedTransient)
    }
}
