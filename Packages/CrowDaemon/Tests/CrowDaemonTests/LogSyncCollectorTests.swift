import Foundation
import Testing
import CrowCore
@testable import CrowDaemon

@Suite struct LogSyncCollectorTests {
    private func collector(resolveSecret: @escaping (String) -> String? = { _ in nil }) -> LogSyncCollector {
        LogSyncCollector(devRoot: "/tmp/does-not-matter", resolveSecret: resolveSecret)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logsync-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: API key resolution

    @Test func resolvesPlaintextKeyLiterally() {
        #expect(collector().resolveAPIKey("sk-citadel-abc") == "sk-citadel-abc")
    }

    @Test func resolvesOpReference() {
        let c = collector { $0 == "op://vault/corveil/key" ? "RESOLVED" : nil }
        #expect(c.resolveAPIKey("op://vault/corveil/key") == "RESOLVED")
    }

    @Test func blankOrUnresolvableKeyIsNil() {
        #expect(collector().resolveAPIKey("   ") == nil)
        #expect(collector { _ in nil }.resolveAPIKey("op://missing") == nil)
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
