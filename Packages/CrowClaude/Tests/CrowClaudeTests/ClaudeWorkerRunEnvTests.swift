import Foundation
import Testing
@testable import CrowClaude

/// `writeCorveilRunEnv` injects the runner credentials + run identity into a
/// worker run's scratch `.claude/settings.local.json` `env` block
/// (corveil/crow#801). Like `writeGatewayEnv`, the file carries the scoped
/// `CORVEIL_API_KEY`, so it must be owner-only (0600); the scratch dir is wiped
/// on finish so the key never persists.
@Suite("ClaudeHookConfigWriter.writeCorveilRunEnv")
struct ClaudeWorkerRunEnvTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-corveilenv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func env(at dir: URL) throws -> [String: Any] {
        let path = dir.appendingPathComponent(".claude/settings.local.json")
        let data = try #require(FileManager.default.contents(atPath: path.path))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(settings["env"] as? [String: Any])
    }

    private func posixPerms(at dir: URL) throws -> Int {
        let path = dir.appendingPathComponent(".claude/settings.local.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return try #require((attrs[.posixPermissions] as? NSNumber)?.intValue)
    }

    @Test func writesAllFourKeysOwnerOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let ok = ClaudeHookConfigWriter.writeCorveilRunEnv(
            dirPath: dir.path,
            corveilURL: "https://corveil.acme.io",
            apiKey: "sk-secret",
            runID: "run-42",
            workerID: "crow-host-1"
        )

        #expect(ok)  // success is reported so the caller can proceed
        #expect(try posixPerms(at: dir) == 0o600)  // carries the scoped API key
        let env = try env(at: dir)
        #expect(env["CORVEIL_URL"] as? String == "https://corveil.acme.io")
        #expect(env["CORVEIL_API_KEY"] as? String == "sk-secret")
        #expect(env["CROW_WORKER_RUN_ID"] as? String == "run-42")
        #expect(env["CROW_WORKER_ID"] as? String == "crow-host-1")
    }

    @Test func mergesWithExistingSettingsAndEnv() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-seed unrelated settings + an unrelated env var — both must survive.
        let claudeDir = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let seed: [String: Any] = ["hooks": ["X": "y"], "env": ["PATH_HINT": "/opt"]]
        let data = try JSONSerialization.data(withJSONObject: seed)
        try data.write(to: claudeDir.appendingPathComponent("settings.local.json"))

        ClaudeHookConfigWriter.writeCorveilRunEnv(
            dirPath: dir.path, corveilURL: "u", apiKey: "k", runID: "r", workerID: "w"
        )

        let env = try env(at: dir)
        #expect(env["PATH_HINT"] as? String == "/opt")   // preserved
        #expect(env["CORVEIL_API_KEY"] as? String == "k") // added

        let path = dir.appendingPathComponent(".claude/settings.local.json")
        let reread = try #require(FileManager.default.contents(atPath: path.path))
        let settings = try #require(try JSONSerialization.jsonObject(with: reread) as? [String: Any])
        #expect(settings["hooks"] != nil)  // unrelated top-level key preserved
    }

    @Test func omitsBlankURLAndKeyButAlwaysWritesRunIdentity() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        ClaudeHookConfigWriter.writeCorveilRunEnv(
            dirPath: dir.path, corveilURL: "", apiKey: "", runID: "r1", workerID: "w1"
        )
        let env = try env(at: dir)
        #expect(env["CORVEIL_URL"] == nil)      // blank ⇒ don't shadow ambient state
        #expect(env["CORVEIL_API_KEY"] == nil)
        #expect(env["CROW_WORKER_RUN_ID"] as? String == "r1")
        #expect(env["CROW_WORKER_ID"] as? String == "w1")
    }

    @Test func returnsFalseWhenTheFileCannotBeWritten() throws {
        // Point `dirPath` at an existing *file*, so creating the `.claude`
        // subdirectory under it fails — the writer must report failure so the
        // caller fails the run rather than launching without credentials (review).
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }

        let ok = ClaudeHookConfigWriter.writeCorveilRunEnv(
            dirPath: file.path, corveilURL: "u", apiKey: "k", runID: "r", workerID: "w"
        )
        #expect(!ok)
    }
}
