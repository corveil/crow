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

        let source = AgentLogSource.directory(
            dir.path, format: .logDir, fileExtension: "jsonl",
            recursive: true, cwdFilter: "/dev/ws/repo-1089")
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
