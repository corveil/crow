import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

/// CROW-1381: Codex runs a project hook only when `config.toml` carries a
/// `[hooks.state."<key>"] trusted_hash` matching it. These pin Crow's copy of
/// the hash and the seed/prune round trip.
@Suite("CodexHookTrust")
struct CodexHookTrustTests {
    private static let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let crowPath = "/Users/x/My Projects/.claude/bin/crow"

    /// Golden values: the `currentHash` that `codex app-server`'s `hooks/list`
    /// reported for these exact entries on codex-cli 0.147.0 and 0.165.0.
    private static let golden = [
        "stop": "sha256:f1818b7b46f0c6225c874c9babd5dde00ec10c815903a95d9cfd7ec29e65fa25",
        "post_tool_use": "sha256:16828869c68076e749b265d7a2f01ee49cab45830b6ab9ccfdf5baa0b037d4b3",
        "interrupt": "sha256:1b2e05af14753c408786fb1f339d32625a4704088c5aa80fad73920c49817db1",
    ]

    private func makeTempDir() throws -> (project: String, config: String, base: String) {
        let base = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
            .resolvingSymlinksInPath()
            .appendingPathComponent("codex-hook-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let project = base.appendingPathComponent("worktree").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        return (project, base.appendingPathComponent("config.toml").path, base.path)
    }

    @Test func commandHashMatchesCodex() {
        let quoted = ShellLaunchArgs.shellQuote(Self.crowPath)
        let sid = Self.sessionID.uuidString
        #expect(CodexHookTrust.commandHash(
            eventLabel: "stop",
            command: "\(quoted) hook-event --session \(sid) --agent codex --event Stop",
            timeout: 5, async: false) == Self.golden["stop"])
        #expect(CodexHookTrust.commandHash(
            eventLabel: "post_tool_use",
            command: "\(quoted) hook-event --session \(sid) --agent codex --event PostToolUse",
            timeout: 5, async: true) == Self.golden["post_tool_use"])
    }

    @Test func sha256MatchesFIPSVectors() {
        #expect(SHA256Digest.hex([]) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256Digest.hex(Array("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // 56 bytes: the padding spills into a second block.
        #expect(SHA256Digest.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
            == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(SHA256Digest.hex(Array(repeating: UInt8(ascii: "a"), count: 1000))
            == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func jsonStringEscapesLikeSerdeJSON() {
        // `/` and non-ASCII stay verbatim; controls use lowercase `\u00xx`.
        #expect(CodexHookTrust.jsonString("a\"b\\c/d\u{01}é\n") == "\"a\\\"b\\\\c/d\\u0001é\\n\"")
    }

    @Test func writerHashesEveryEventItWrites() {
        let writer = CodexHookConfigWriter(asyncHooksSupported: true)
        let hashes = writer.hookTrustHashes(sessionID: Self.sessionID, crowPath: Self.crowPath)
        #expect(Set(hashes.keys) == [
            "session_start", "pre_tool_use", "post_tool_use", "user_prompt_submit",
            "stop", "permission_request", "interrupt",
        ])
        for (label, hash) in Self.golden {
            #expect(hashes[label] == hash, "\(label)")
        }
    }

    @Test func asyncSupportChangesOnlyTheAsyncHash() {
        let sync = CodexHookConfigWriter(asyncHooksSupported: false)
            .hookTrustHashes(sessionID: Self.sessionID, crowPath: Self.crowPath)
        let async = CodexHookConfigWriter(asyncHooksSupported: true)
            .hookTrustHashes(sessionID: Self.sessionID, crowPath: Self.crowPath)
        #expect(sync["post_tool_use"] != async["post_tool_use"])
        #expect(sync["stop"] == async["stop"])
    }

    @Test func hashesChangeWithTheSession() {
        let writer = CodexHookConfigWriter()
        let a = writer.hookTrustHashes(sessionID: UUID(), crowPath: Self.crowPath)
        let b = writer.hookTrustHashes(sessionID: UUID(), crowPath: Self.crowPath)
        #expect(a["stop"] != b["stop"])
    }

    @Test func seedTrustWritesHookStateTables() throws {
        let (project, config, base) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let hashes = CodexHookConfigWriter()
            .hookTrustHashes(sessionID: Self.sessionID, crowPath: Self.crowPath)
        #expect(CodexTrustSeeder.seedTrust(
            projectPath: project, hookHashes: hashes, codexConfigPath: config) == .seeded)

        let toml = try String(contentsOfFile: config, encoding: .utf8)
        #expect(toml.contains("[projects.\"\(project)\"]"))
        for (label, hash) in hashes {
            #expect(toml.contains("[hooks.state.\"\(project)/.codex/hooks.json:\(label):0:0\"]\ntrusted_hash = \"\(hash)\""))
        }

        // Same session again: nothing to write.
        #expect(CodexTrustSeeder.seedTrust(
            projectPath: project, hookHashes: hashes, codexConfigPath: config) == .alreadyTrusted)
    }

    @Test func reseedReplacesTheHashInPlace() throws {
        let (project, config, base) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let writer = CodexHookConfigWriter()
        CodexTrustSeeder.seedTrust(
            projectPath: project,
            hookHashes: writer.hookTrustHashes(sessionID: UUID(), crowPath: Self.crowPath),
            codexConfigPath: config)
        let second = writer.hookTrustHashes(sessionID: Self.sessionID, crowPath: Self.crowPath)
        #expect(CodexTrustSeeder.seedTrust(
            projectPath: project, hookHashes: second, codexConfigPath: config) == .seeded)

        let toml = try String(contentsOfFile: config, encoding: .utf8)
        let stopHeader = "[hooks.state.\"\(project)/.codex/hooks.json:stop:0:0\"]"
        #expect(toml.components(separatedBy: stopHeader).count == 2, "one table per key")
        #expect(toml.components(separatedBy: "trusted_hash").count == 8, "seven entries, no stale ones")
        #expect(toml.contains("\(stopHeader)\ntrusted_hash = \"\(second["stop"]!)\""))
    }

    @Test func removeHookTrustDropsOnlyThatProjectsTables() throws {
        let (project, config, base) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let existing = """
        model = "gpt-5.5"

        [hooks.state."/other/.codex/hooks.json:stop:0:0"]
        trusted_hash = "sha256:keep"

        """
        try existing.write(toFile: config, atomically: true, encoding: .utf8)
        let hashes = CodexHookConfigWriter()
            .hookTrustHashes(sessionID: Self.sessionID, crowPath: Self.crowPath)
        CodexTrustSeeder.seedTrust(projectPath: project, hookHashes: hashes, codexConfigPath: config)
        try (String(contentsOfFile: config, encoding: .utf8) + "\n[desktop]\nfoo = 1\n")
            .write(toFile: config, atomically: true, encoding: .utf8)

        #expect(CodexTrustSeeder.removeHookTrust(projectPath: project, codexConfigPath: config) == .seeded)

        let toml = try String(contentsOfFile: config, encoding: .utf8)
        #expect(!toml.contains("\(project)/.codex/hooks.json"))
        #expect(toml.contains("model = \"gpt-5.5\""))
        #expect(toml.contains("[hooks.state.\"/other/.codex/hooks.json:stop:0:0\"]\ntrusted_hash = \"sha256:keep\""))
        #expect(toml.contains("[projects.\"\(project)\"]\ntrust_level = \"trusted\""))
        #expect(toml.contains("[desktop]\nfoo = 1"))

        // Nothing left to remove.
        #expect(CodexTrustSeeder.removeHookTrust(projectPath: project, codexConfigPath: config) == .alreadyTrusted)
    }

    @Test func removeHookTrustNeverCreatesTheConfig() throws {
        let (project, config, base) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(CodexTrustSeeder.removeHookTrust(projectPath: project, codexConfigPath: config) == .alreadyTrusted)
        #expect(!FileManager.default.fileExists(atPath: config))
    }

    @Test func removeHookConfigPrunesTrustForCrowOwnedFile() throws {
        let (project, config, base) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let writer = CodexHookConfigWriter(codexConfigPath: config)
        try writer.writeHookConfig(worktreePath: project, sessionID: Self.sessionID, crowPath: Self.crowPath)
        CodexTrustSeeder.seedTrust(
            projectPath: project,
            hookHashes: writer.hookTrustHashes(sessionID: Self.sessionID, crowPath: Self.crowPath),
            codexConfigPath: config)

        writer.removeHookConfig(worktreePath: project)

        let toml = try String(contentsOfFile: config, encoding: .utf8)
        #expect(!toml.contains("hooks.state"))
    }

    @Test func removeHookConfigKeepsTrustForUserFile() throws {
        let (project, config, base) = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: base) }

        let codexDir = (project as NSString).appendingPathComponent(".codex")
        try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
            .write(toFile: (codexDir as NSString).appendingPathComponent("hooks.json"),
                   atomically: true, encoding: .utf8)
        let userTrust = "[hooks.state.\"\(project)/.codex/hooks.json:stop:0:0\"]\ntrusted_hash = \"sha256:user\"\n"
        try userTrust.write(toFile: config, atomically: true, encoding: .utf8)

        CodexHookConfigWriter(codexConfigPath: config).removeHookConfig(worktreePath: project)

        #expect(try String(contentsOfFile: config, encoding: .utf8) == userTrust)
    }
}
