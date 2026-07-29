import Foundation
import Testing
@testable import CrowGrok

@Suite("GrokTrustSeeder")
struct GrokTrustSeederTests {

    private func makeTempStore() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trusted_folders.toml")
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func seedsTrustForFolder() throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        let outcome = GrokTrustSeeder.seedTrust(
            projectPath: "/abs/repo", trustStorePath: store.path)
        #expect(outcome == .seeded)

        let content = try read(store)
        // Grok's verified schema: [folders."/abs/repo"] trusted = true
        #expect(content.contains("[folders.\"/abs/repo\"]"))
        #expect(content.contains("trusted = true"))
    }

    @Test func idempotentSecondSeedIsAlreadyTrusted() throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        #expect(GrokTrustSeeder.seedTrust(projectPath: "/abs/repo", trustStorePath: store.path) == .seeded)
        #expect(GrokTrustSeeder.seedTrust(projectPath: "/abs/repo", trustStorePath: store.path) == .alreadyTrusted)
    }

    @Test func preservesOtherFoldersDecisions() throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        // Pre-seed an unrelated folder's decision.
        try """
        [folders."/other/repo"]
        trusted = true
        decided_at = 1780000000

        """.write(to: store, atomically: true, encoding: .utf8)

        #expect(GrokTrustSeeder.seedTrust(projectPath: "/abs/repo", trustStorePath: store.path) == .seeded)

        let content = try read(store)
        // Both folders present; the pre-existing decided_at is untouched.
        #expect(content.contains("[folders.\"/other/repo\"]"))
        #expect(content.contains("decided_at = 1780000000"))
        #expect(content.contains("[folders.\"/abs/repo\"]"))
    }

    @Test func flipsStaleUntrustedToTrusted() throws {
        let store = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: store.deletingLastPathComponent()) }

        try """
        [folders."/abs/repo"]
        trusted = false

        """.write(to: store, atomically: true, encoding: .utf8)

        #expect(GrokTrustSeeder.seedTrust(projectPath: "/abs/repo", trustStorePath: store.path) == .seeded)

        let content = try read(store)
        #expect(content.contains("trusted = true"))
        #expect(!content.contains("trusted = false"))
    }

    @Test func escapesTomlSpecialCharactersInPathKey() {
        // A path with a quote/backslash must not break the `[folders."…"]` header.
        #expect(GrokTrustSeeder.escapeTomlString("/a\"b\\c") == "/a\\\"b\\\\c")
    }

    @Test func upsertProducesValidHeaderForQuotedPath() {
        let out = GrokTrustSeeder.upsertTrusted("", folderPath: "/a\"b")
        #expect(out.contains("[folders.\"/a\\\"b\"]"))
        #expect(out.contains("trusted = true"))
    }
}
