import Foundation
import Testing
@testable import CrowAntigravity

@Suite("AntigravityMCPConfigWriter")
struct AntigravityMCPConfigWriterTests {

    // MARK: - Translation

    @Test func translatesClaudeLocalServer() throws {
        let claude: [String: Any] = [
            "command": "uvx",
            "args": ["mcp-atlassian", "--transport", "stdio"],
            "env": ["JIRA_URL": "https://acme.example.net", "JIRA_API_TOKEN": "secret"],
        ]
        let out = try #require(AntigravityMCPConfigWriter.translateClaudeServer(claude))
        #expect(out["command"] as? String == "uvx")
        #expect(out["args"] as? [String] == ["mcp-atlassian", "--transport", "stdio"])
        let env = try #require(out["env"] as? [String: String])
        #expect(env["JIRA_API_TOKEN"] == "secret")
        #expect(out["serverUrl"] == nil)
        #expect(out["url"] == nil)
    }

    @Test func translatesClaudeRemoteServerUrlToServerUrl() throws {
        let claude: [String: Any] = [
            "type": "http",
            "url": "https://mcp.example.net/jira",
            "headers": ["Authorization": "Bearer x"],
        ]
        let out = try #require(AntigravityMCPConfigWriter.translateClaudeServer(claude))
        #expect(out["serverUrl"] as? String == "https://mcp.example.net/jira")
        #expect(out["command"] == nil)
        #expect(out["url"] == nil)
        let headers = try #require(out["headers"] as? [String: String])
        #expect(headers["Authorization"] == "Bearer x")
    }

    @Test func translatesHttpUrlAlias() throws {
        let out = try #require(AntigravityMCPConfigWriter.translateClaudeServer([
            "httpUrl": "https://legacy.example.net/mcp",
        ]))
        #expect(out["serverUrl"] as? String == "https://legacy.example.net/mcp")
    }

    @Test func translateReturnsNilForUnusableServer() {
        #expect(AntigravityMCPConfigWriter.translateClaudeServer(["foo": "bar"]) == nil)
    }

    // MARK: - End-to-end

    private struct Harness {
        let tmp: URL
        let claude: URL
        let configHome: URL
        let record: String
        let targetPath: String

        func run() -> AntigravityMCPConfigWriter.Outcome {
            AntigravityMCPConfigWriter.installMCPConfig(
                configHome: configHome.path,
                claudeJSONPath: claude.path,
                mirrorRecordPath: record)
        }

        func root() throws -> [String: Any] {
            let data = try #require(FileManager.default.contents(atPath: targetPath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func jira() throws -> [String: Any] {
            let servers = try #require(try root()["mcpServers"] as? [String: Any])
            return try #require(servers["jira"] as? [String: Any])
        }

        func writeClaude(jira: [String: Any]?) throws {
            let root: [String: Any]
            if let jira {
                root = ["mcpServers": ["jira": jira]]
            } else {
                root = ["mcpServers": [String: Any]()]
            }
            try JSONSerialization.data(withJSONObject: root).write(to: claude)
        }
    }

    private func makeHarness(
        jira: [String: Any]? = nil,
        existing: [String: Any]? = nil
    ) throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let claude = tmp.appendingPathComponent(".claude.json")
        if let jira {
            try JSONSerialization.data(withJSONObject: ["mcpServers": ["jira": jira]])
                .write(to: claude)
        }
        let configHome = tmp.appendingPathComponent("gemini-config")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        if let existing {
            try JSONSerialization.data(withJSONObject: existing)
                .write(to: configHome.appendingPathComponent("mcp_config.json"))
        }
        return Harness(
            tmp: tmp,
            claude: claude,
            configHome: configHome,
            record: tmp.appendingPathComponent("mirror.json").path,
            targetPath: configHome.appendingPathComponent("mcp_config.json").path)
    }

    @Test func writesJiraServerFromClaudeConfig() throws {
        let h = try makeHarness(jira: [
            "command": "uvx", "args": ["mcp-atlassian"],
            "env": ["JIRA_API_TOKEN": "secret"],
        ])
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .registered)
        let jira = try h.jira()
        #expect(jira["command"] as? String == "uvx")
        #expect(jira["args"] as? [String] == ["mcp-atlassian"])
        let env = try #require(jira["env"] as? [String: Any])
        #expect(env["JIRA_API_TOKEN"] as? String == "secret")

        let perms = try #require(
            (try FileManager.default.attributesOfItem(atPath: h.targetPath))[.posixPermissions] as? NSNumber)
        #expect(perms.int16Value == 0o600)
        let recordPerms = try #require(
            (try FileManager.default.attributesOfItem(atPath: h.record))[.posixPermissions] as? NSNumber)
        #expect(recordPerms.int16Value == 0o600)
    }

    @Test func noSourceWhenClaudeHasNoJira() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try JSONSerialization.data(withJSONObject: ["mcpServers": ["other": ["command": "x"]]])
            .write(to: h.claude)
        #expect(h.run() == .noSource)
        #expect(FileManager.default.fileExists(atPath: h.targetPath) == false)
    }

    @Test func noSourceWhenClaudeConfigMissing() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .noSource)
        #expect(FileManager.default.fileExists(atPath: h.targetPath) == false)
    }

    @Test func mergePreservesExistingServers() throws {
        let h = try makeHarness(
            jira: ["command": "uvx", "args": ["mcp-atlassian"]],
            existing: ["mcpServers": ["github": ["command": "npx"]]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .registered)
        let servers = try #require(try h.root()["mcpServers"] as? [String: Any])
        #expect(servers["github"] != nil)
        #expect(servers["jira"] != nil)
    }

    @Test func secondRunIsUnchanged() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        #expect(h.run() == .unchanged)
    }

    @Test func skipsUserAuthoredJira() throws {
        let h = try makeHarness(
            jira: ["command": "uvx", "args": ["mcp-atlassian"]],
            existing: ["mcpServers": ["jira": ["command": "my-own-jira"]]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .skippedUserOwned)
        let jira = try h.jira()
        #expect(jira["command"] as? String == "my-own-jira")
        #expect(jira["args"] == nil)
    }

    @Test func unMirrorsWhenSourceRemoved() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)

        try h.writeClaude(jira: nil)
        #expect(h.run() == .removed)
        #expect(FileManager.default.fileExists(atPath: h.targetPath) == false)
        #expect(h.run() == .noSource)
    }

    @Test func unMirrorPreservesSiblingServers() throws {
        let h = try makeHarness(
            jira: ["command": "uvx"],
            existing: ["mcpServers": ["github": ["command": "npx"]]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        try h.writeClaude(jira: nil)
        #expect(h.run() == .removed)
        let servers = try #require(try h.root()["mcpServers"] as? [String: Any])
        #expect(servers["github"] != nil)
        #expect(servers["jira"] == nil)
    }

    @Test func doesNotUnMirrorUserAuthoredOnSourceRemoval() throws {
        let h = try makeHarness(
            existing: ["mcpServers": ["jira": ["command": "mine"]]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try h.writeClaude(jira: nil)
        #expect(h.run() == .skippedUserOwned)
        #expect(try h.jira()["command"] as? String == "mine")
    }

    @Test func deletingEntryIsDurableOptOut() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)

        try JSONSerialization.data(withJSONObject: ["mcpServers": [String: Any]()])
            .write(to: URL(fileURLWithPath: h.targetPath))
        #expect(h.run() == .skippedUserOwned)
        #expect((try h.root()["mcpServers"] as? [String: Any])?["jira"] == nil)

        try h.writeClaude(jira: nil)
        #expect(h.run() == .noSource)
        try h.writeClaude(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        #expect(h.run() == .skippedUserOwned)
        #expect((try h.root()["mcpServers"] as? [String: Any])?["jira"] == nil)
    }

    @Test func refreshesCrowOwnedEntryWhenSourceChanges() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["old"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)

        try h.writeClaude(jira: ["command": "uvx", "args": ["new"]])
        #expect(h.run() == .registered)
        #expect(try h.jira()["args"] as? [String] == ["new"])
    }

    @Test func claudeHasJiraServerProbesSource() throws {
        let h = try makeHarness(jira: ["command": "uvx"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(AntigravityMCPConfigWriter.claudeHasJiraServer(claudeJSONPath: h.claude.path))
        try h.writeClaude(jira: nil)
        #expect(AntigravityMCPConfigWriter.claudeHasJiraServer(claudeJSONPath: h.claude.path) == false)
        #expect(AntigravityMCPConfigWriter.claudeHasJiraServer(
            claudeJSONPath: h.tmp.appendingPathComponent("missing.json").path) == false)
    }

    @Test func promotesProjectScopedClaudeJira() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try JSONSerialization.data(withJSONObject: [
            "projects": [
                "/some/repo": [
                    "mcpServers": ["jira": ["command": "uvx", "args": ["mcp-atlassian"]]],
                ],
            ],
        ]).write(to: h.claude)
        #expect(h.run() == .registered)
        #expect(try h.jira()["command"] as? String == "uvx")
    }

    @Test func refusesUnparseableTarget() throws {
        let h = try makeHarness(jira: ["command": "uvx"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try "{ \"mcpServers\": {".write(
            to: URL(fileURLWithPath: h.targetPath), atomically: true, encoding: .utf8)
        #expect(h.run() == .skippedUnparseable)
    }
}
