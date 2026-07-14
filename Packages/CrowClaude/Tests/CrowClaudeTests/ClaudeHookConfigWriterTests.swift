import Foundation
import Testing
import CrowCore
@testable import CrowClaude

/// Re-homes the manager-hook secret-permission invariant dropped with the root
/// suite (`ManagerHookConfigTests`, CROW-607). `writeGatewayEnv` is the only
/// `0o600` path in `ClaudeHookConfigWriter`: the `env` block can carry a
/// resolved AI-gateway bearer token, so the file it writes
/// (`.claude/settings.local.json`) must be owner-only, matching
/// `ConfigStore`'s `0o600` on `config.json` (CROW-402).
@Suite("ClaudeHookConfigWriter.writeGatewayEnv")
struct ClaudeHookConfigWriterTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-gwenv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settings(at dir: URL) throws -> [String: Any] {
        let path = dir.appendingPathComponent(".claude/settings.local.json")
        let data = try #require(FileManager.default.contents(atPath: path.path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func posixPerms(at dir: URL) throws -> Int {
        let path = dir.appendingPathComponent(".claude/settings.local.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return try #require((attrs[.posixPermissions] as? NSNumber)?.intValue)
    }

    @Test func writesGatewayEnvOwnerOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        ClaudeHookConfigWriter.writeGatewayEnv(
            dirPath: dir.path,
            resolved: .init(baseURL: "https://gw.example", customHeaders: "X-Api-Key: secret"))

        // The bearer-token-bearing file must be readable only by its owner.
        #expect(try posixPerms(at: dir) == 0o600)

        let env = try #require(try settings(at: dir)["env"] as? [String: Any])
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "https://gw.example")
        #expect(env["ANTHROPIC_CUSTOM_HEADERS"] as? String == "X-Api-Key: secret")
    }

    @Test func clearingRemovesGatewayKeysButPreservesOtherSettings() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-seed a settings file with our gateway keys, an unrelated env var,
        // and an unrelated top-level key — none of which we own.
        let claudeDir = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": "https://old.gw",
                "ANTHROPIC_CUSTOM_HEADERS": "X-Api-Key: old",
                "USER_VAR": "keep-me",
            ],
            "permissions": ["allow": ["Bash"]],
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed)
        try seedData.write(to: claudeDir.appendingPathComponent("settings.local.json"))

        ClaudeHookConfigWriter.writeGatewayEnv(dirPath: dir.path, resolved: nil)

        let merged = try settings(at: dir)
        let env = try #require(merged["env"] as? [String: Any])
        #expect(env["ANTHROPIC_BASE_URL"] == nil)          // gateway keys cleared…
        #expect(env["ANTHROPIC_CUSTOM_HEADERS"] == nil)
        #expect(env["USER_VAR"] as? String == "keep-me")   // …unrelated env var preserved
        #expect(merged["permissions"] != nil)              // unrelated top-level key preserved
        // Re-write still restricts the file (unrelated USER_VAR could be secret too).
        #expect(try posixPerms(at: dir) == 0o600)
    }
}
