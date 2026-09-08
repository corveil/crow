import Foundation
import Testing
@testable import CrowMuse

@Suite("MuseMCPConfigWriter")
struct MuseMCPConfigWriterTests {

    // MARK: - Translation

    @Test func translatesClaudeLocalServer() throws {
        let claude: [String: Any] = [
            "command": "uvx",
            "args": ["mcp-atlassian", "--transport", "stdio"],
            "env": ["JIRA_URL": "https://acme.example.net", "JIRA_API_TOKEN": "secret"],
        ]
        let out = try #require(MuseMCPConfigWriter.translateClaudeServer(claude))
        #expect(out["transport"] as? String == "stdio")
        #expect(out["command"] as? String == "uvx")
        #expect(out["args"] as? [String] == ["mcp-atlassian", "--transport", "stdio"])
        #expect(out["mode"] as? String == "optional")
        let env = try #require(out["env"] as? [String: String])
        #expect(env["JIRA_API_TOKEN"] == "secret")
        #expect(out["url"] == nil)
    }

    @Test func translatesClaudeRemoteServerToStreamableHTTP() throws {
        let claude: [String: Any] = [
            "type": "http",
            "url": "https://mcp.example.net/jira",
            "headers": ["Authorization": "Bearer x"],
        ]
        let out = try #require(MuseMCPConfigWriter.translateClaudeServer(claude))
        #expect(out["transport"] as? String == "streamable_http")
        #expect(out["url"] as? String == "https://mcp.example.net/jira")
        #expect(out["command"] == nil)
        #expect(out["mode"] as? String == "optional")
        let headers = try #require(out["headers"] as? [String: String])
        #expect(headers["Authorization"] == "Bearer x")
    }

    @Test func translatesHttpUrlAlias() throws {
        let out = try #require(MuseMCPConfigWriter.translateClaudeServer([
            "httpUrl": "https://legacy.example.net/mcp",
        ]))
        #expect(out["transport"] as? String == "streamable_http")
        #expect(out["url"] as? String == "https://legacy.example.net/mcp")
    }

    @Test func translateReturnsNilForUnusableServer() {
        #expect(MuseMCPConfigWriter.translateClaudeServer(["foo": "bar"]) == nil)
    }

    // MARK: - End-to-end

    private struct Harness {
        let tmp: URL
        let claude: URL
        let configHome: URL
        let record: String
        let targetPath: String

        func run() -> MuseMCPConfigWriter.Outcome {
            MuseMCPConfigWriter.installMCPConfig(
                configHome: configHome.path,
                claudeJSONPath: claude.path,
                mirrorRecordPath: record)
        }

        func root() throws -> [String: Any] {
            let data = try #require(FileManager.default.contents(atPath: targetPath))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func jira() throws -> [String: Any] {
            let servers = try #require(try root()["mcp_servers"] as? [String: Any])
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
            .appendingPathComponent("muse-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let claude = tmp.appendingPathComponent(".claude.json")
        if let jira {
            try JSONSerialization.data(withJSONObject: ["mcpServers": ["jira": jira]])
                .write(to: claude)
        }
        let configHome = tmp.appendingPathComponent("muse-config")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        if let existing {
            try JSONSerialization.data(withJSONObject: existing)
                .write(to: configHome.appendingPathComponent("settings.json"))
        }
        return Harness(
            tmp: tmp,
            claude: claude,
            configHome: configHome,
            record: tmp.appendingPathComponent("mirror.json").path,
            targetPath: configHome.appendingPathComponent("settings.json").path)
    }

    @Test func writesJiraServerFromClaudeConfig() throws {
        let h = try makeHarness(jira: [
            "command": "uvx", "args": ["mcp-atlassian"],
            "env": ["JIRA_API_TOKEN": "secret"],
        ])
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .registered)
        let root = try h.root()
        #expect((root["schema_version"] as? NSNumber)?.intValue == 1)
        let jira = try h.jira()
        #expect(jira["transport"] as? String == "stdio")
        #expect(jira["command"] as? String == "uvx")
        #expect(jira["args"] as? [String] == ["mcp-atlassian"])
        #expect(jira["mode"] as? String == "optional")
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

    @Test func mergePreservesExistingServersAndSettings() throws {
        let h = try makeHarness(
            jira: ["command": "uvx", "args": ["mcp-atlassian"]],
            existing: [
                "schema_version": 1,
                "model": "muse-spark-1.2",
                "mcp_servers": ["github": ["transport": "stdio", "command": "npx"]],
            ])
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .registered)
        let root = try h.root()
        #expect((root["schema_version"] as? NSNumber)?.intValue == 1)
        #expect(root["model"] as? String == "muse-spark-1.2")
        let servers = try #require(root["mcp_servers"] as? [String: Any])
        #expect(servers["github"] != nil)
        #expect(servers["jira"] != nil)
    }

    @Test func injectsSchemaVersionWhenCreatingFile() throws {
        let h = try makeHarness(jira: ["command": "uvx"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        #expect((try h.root()["schema_version"] as? NSNumber)?.intValue == 1)
    }

    @Test func injectsSchemaVersionWhenExistingFileOmitsIt() throws {
        let h = try makeHarness(
            jira: ["command": "uvx"],
            existing: ["model": "muse-spark-1.2"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        let root = try h.root()
        #expect((root["schema_version"] as? NSNumber)?.intValue == 1)
        #expect(root["model"] as? String == "muse-spark-1.2")
    }

    @Test func doesNotOverwriteExistingSchemaVersion() throws {
        let h = try makeHarness(
            jira: ["command": "uvx"],
            existing: ["schema_version": 99])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        #expect((try h.root()["schema_version"] as? NSNumber)?.intValue == 99)
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
            existing: [
                "schema_version": 1,
                "mcp_servers": ["jira": ["transport": "stdio", "command": "my-own-jira"]],
            ])
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
        let root = try h.root()
        #expect(root["mcp_servers"] == nil)
        #expect((root["schema_version"] as? NSNumber)?.intValue == 1)
        #expect(FileManager.default.fileExists(atPath: h.targetPath))
        let text = try String(contentsOfFile: h.targetPath, encoding: .utf8)
        #expect(text.contains("\"schema_version\""))
        #expect(text.contains(": 1") || text.contains(":1"))
        #expect(text.contains("true") == false)
        #expect(h.run() == .noSource)
    }

    @Test func unMirrorPreservesSiblingServers() throws {
        let h = try makeHarness(
            jira: ["command": "uvx"],
            existing: [
                "schema_version": 1,
                "mcp_servers": ["github": ["transport": "stdio", "command": "npx"]],
            ])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        try h.writeClaude(jira: nil)
        #expect(h.run() == .removed)
        let servers = try #require(try h.root()["mcp_servers"] as? [String: Any])
        #expect(servers["github"] != nil)
        #expect(servers["jira"] == nil)
    }

    @Test func doesNotUnMirrorUserAuthoredOnSourceRemoval() throws {
        let h = try makeHarness(
            existing: [
                "schema_version": 1,
                "mcp_servers": ["jira": ["transport": "stdio", "command": "mine"]],
            ])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try h.writeClaude(jira: nil)
        #expect(h.run() == .skippedUserOwned)
        #expect(try h.jira()["command"] as? String == "mine")
    }

    @Test func deletingEntryIsDurableOptOut() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)

        try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "mcp_servers": [String: Any](),
        ]).write(to: URL(fileURLWithPath: h.targetPath))
        #expect(h.run() == .skippedUserOwned)
        #expect((try h.root()["mcp_servers"] as? [String: Any])?["jira"] == nil)

        try h.writeClaude(jira: nil)
        #expect(h.run() == .noSource)
        try h.writeClaude(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        #expect(h.run() == .skippedUserOwned)
        #expect((try h.root()["mcp_servers"] as? [String: Any])?["jira"] == nil)
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
        #expect(MuseMCPConfigWriter.claudeHasJiraServer(claudeJSONPath: h.claude.path))
        try h.writeClaude(jira: nil)
        #expect(MuseMCPConfigWriter.claudeHasJiraServer(claudeJSONPath: h.claude.path) == false)
        #expect(MuseMCPConfigWriter.claudeHasJiraServer(
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
        #expect((try h.root()["schema_version"] as? NSNumber)?.intValue == 1)
    }

    @Test func refusesUnparseableTarget() throws {
        let h = try makeHarness(jira: ["command": "uvx"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try "{ \"mcp_servers\": {".write(
            to: URL(fileURLWithPath: h.targetPath), atomically: true, encoding: .utf8)
        #expect(h.run() == .skippedUnparseable)
    }

    @Test func refusesNonObjectMcpServers() throws {
        let h = try makeHarness(
            jira: ["command": "uvx"],
            existing: ["schema_version": 1, "mcp_servers": "not-an-object"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .skippedUnparseable)
    }
}
