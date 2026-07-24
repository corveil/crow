import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("CodexTrustSeeder")
struct CodexTrustSeederTests {
    /// A canonical (symlink-resolved) temp dir so `seedTrust`'s raw+resolved
    /// dual-write collapses to a single `[projects."…"]` entry, keeping
    /// assertions deterministic.
    private func makeTempDir() throws -> (project: String, config: String) {
        let base = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .resolvingSymlinksInPath()
            .appendingPathComponent("codex-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let project = base.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let config = base.appendingPathComponent("config.toml").path
        return (project, config)
    }

    @Test func seedTrustCreatesFreshFile() throws {
        let (project, config) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: (config as NSString).deletingLastPathComponent) }

        let outcome = CodexTrustSeeder.seedTrust(projectPath: project, codexConfigPath: config)
        #expect(outcome == .seeded)

        let toml = try String(contentsOfFile: config, encoding: .utf8)
        #expect(toml.contains("[projects.\"\(project)\"]"))
        #expect(toml.contains("trust_level = \"trusted\""))
    }

    @Test func seedTrustPreservesExistingConfig() throws {
        let (project, config) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: (config as NSString).deletingLastPathComponent) }

        let existing = """
        model = "gpt-5.5"

        [model_providers.corveil]
        base_url = "https://corveil.io/v1"
        api_key = "sk-secret-do-not-lose"

        [projects."/some/other/path"]
        trust_level = "trusted"
        """
        try existing.write(toFile: config, atomically: true, encoding: .utf8)

        let outcome = CodexTrustSeeder.seedTrust(projectPath: project, codexConfigPath: config)
        #expect(outcome == .seeded)

        let toml = try String(contentsOfFile: config, encoding: .utf8)
        // User content survives.
        #expect(toml.contains("model = \"gpt-5.5\""))
        #expect(toml.contains("api_key = \"sk-secret-do-not-lose\""))
        #expect(toml.contains("[projects.\"/some/other/path\"]"))
        // New project trusted.
        #expect(toml.contains("[projects.\"\(project)\"]"))
    }

    @Test func seedTrustIsIdempotent() throws {
        let (project, config) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: (config as NSString).deletingLastPathComponent) }

        let first = CodexTrustSeeder.seedTrust(projectPath: project, codexConfigPath: config)
        #expect(first == .seeded)
        let afterFirst = try String(contentsOfFile: config, encoding: .utf8)

        let second = CodexTrustSeeder.seedTrust(projectPath: project, codexConfigPath: config)
        #expect(second == .alreadyTrusted)
        let afterSecond = try String(contentsOfFile: config, encoding: .utf8)
        #expect(afterFirst == afterSecond)
    }

    @Test func seedTrustUpgradesUntrustedProject() throws {
        let (project, config) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: (config as NSString).deletingLastPathComponent) }

        let existing = """
        [projects."\(project)"]
        trust_level = "untrusted"
        """
        try existing.write(toFile: config, atomically: true, encoding: .utf8)

        let outcome = CodexTrustSeeder.seedTrust(projectPath: project, codexConfigPath: config)
        #expect(outcome == .seeded)

        let toml = try String(contentsOfFile: config, encoding: .utf8)
        #expect(toml.contains("trust_level = \"trusted\""))
        #expect(!toml.contains("trust_level = \"untrusted\""))
    }
}
