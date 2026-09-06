import Foundation
import Testing
@testable import CrowGrok

@Suite("GrokMCPConfigWriter")
struct GrokMCPConfigWriterTests {

    // MARK: - Translation

    @Test func translatesClaudeLocalServer() throws {
        let claude: [String: Any] = [
            "command": "uvx",
            "args": ["mcp-atlassian", "--transport", "stdio"],
            "env": ["JIRA_URL": "https://acme.example.net", "JIRA_API_TOKEN": "secret"],
        ]
        let out = try #require(GrokMCPConfigWriter.translateClaudeServer(name: "jira", def: claude))
        #expect(out.command == "uvx")
        #expect(out.args == ["mcp-atlassian", "--transport", "stdio"])
        #expect(out.env.contains(where: { $0 == ("JIRA_API_TOKEN", "secret") }))
        #expect(out.url == nil)

        let block = GrokMCPConfigWriter.serverBlock(out)
        #expect(block.contains("[mcp_servers.jira]"))
        #expect(block.contains("command = \"uvx\""))
        #expect(block.contains("JIRA_API_TOKEN = \"secret\""))
    }

    @Test func translatesClaudeRemoteServerWithHeaders() throws {
        let claude: [String: Any] = [
            "type": "http",
            "url": "https://mcp.example.net/jira",
            "headers": ["Authorization": "Bearer x"],
        ]
        let out = try #require(GrokMCPConfigWriter.translateClaudeServer(name: "jira", def: claude))
        #expect(out.url == "https://mcp.example.net/jira")
        #expect(out.command == nil)
        #expect(out.headers.count == 1)
        #expect(out.headers.first?.0 == "Authorization")
        #expect(out.headers.first?.1 == "Bearer x")

        let block = GrokMCPConfigWriter.serverBlock(out)
        #expect(block.contains("url = \"https://mcp.example.net/jira\""))
        #expect(block.contains("Authorization = \"Bearer x\""))
    }

    @Test func translateReturnsNilForUnusableServer() {
        #expect(GrokMCPConfigWriter.translateClaudeServer(name: "jira", def: ["foo": "bar"]) == nil)
    }

    // MARK: - End-to-end

    private struct Harness {
        let tmp: URL
        let claude: URL
        let grokHome: URL
        let record: String
        let tomlPath: String

        func run() -> GrokMCPConfigWriter.Outcome {
            GrokMCPConfigWriter.installMCPConfig(
                grokHome: grokHome.path,
                claudeJSONPath: claude.path,
                mirrorRecordPath: record)
        }

        func toml() throws -> String {
            try String(contentsOfFile: tomlPath, encoding: .utf8)
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
        existingToml: String? = nil
    ) throws -> Harness {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let claude = tmp.appendingPathComponent(".claude.json")
        if let jira {
            try JSONSerialization.data(withJSONObject: ["mcpServers": ["jira": jira]])
                .write(to: claude)
        }
        let grokHome = tmp.appendingPathComponent("grok")
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)
        if let existingToml {
            try existingToml.write(
                to: grokHome.appendingPathComponent("config.toml"),
                atomically: true, encoding: .utf8)
        }
        return Harness(
            tmp: tmp,
            claude: claude,
            grokHome: grokHome,
            record: tmp.appendingPathComponent("mirror.json").path,
            tomlPath: grokHome.appendingPathComponent("config.toml").path)
    }

    @Test func writesJiraTableFromClaudeConfig() throws {
        let h = try makeHarness(jira: [
            "command": "uvx", "args": ["mcp-atlassian"],
            "env": ["JIRA_API_TOKEN": "secret"],
        ])
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .registered)
        let toml = try h.toml()
        #expect(toml.contains("[mcp_servers.jira]"))
        #expect(toml.contains("command = \"uvx\""))
        #expect(toml.contains("JIRA_API_TOKEN = \"secret\""))

        let perms = try #require(
            (try FileManager.default.attributesOfItem(atPath: h.tomlPath))[.posixPermissions] as? NSNumber)
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
        #expect(FileManager.default.fileExists(atPath: h.tomlPath) == false)
    }

    @Test func noSourceWhenClaudeConfigMissing() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .noSource)
        #expect(FileManager.default.fileExists(atPath: h.tomlPath) == false)
    }

    @Test func mergePreservesExistingGrokTables() throws {
        let h = try makeHarness(
            jira: ["command": "uvx", "args": ["mcp-atlassian"]],
            existingToml: """
            [models]
            default = "grok-build"

            [mcp_servers.github]
            command = "npx"
            """)
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .registered)
        let toml = try h.toml()
        #expect(toml.contains("[models]"))
        #expect(toml.contains("default = \"grok-build\""))
        #expect(toml.contains("[mcp_servers.github]"))
        #expect(toml.contains("[mcp_servers.jira]"))
    }

    @Test func secondRunIsUnchanged() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        #expect(h.run() == .unchanged)
    }

    @Test func skipsUserAuthoredJiraTable() throws {
        let h = try makeHarness(
            jira: ["command": "uvx", "args": ["mcp-atlassian"]],
            existingToml: """
            [mcp_servers.jira]
            command = "my-own-jira"
            """)
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .skippedUserOwned)
        let toml = try h.toml()
        #expect(toml.contains("command = \"my-own-jira\""))
        #expect(toml.contains("uvx") == false)
    }

    @Test func skipsInlineUserAuthoredJira() throws {
        let h = try makeHarness(
            jira: ["command": "uvx"],
            existingToml: """
            [mcp_servers]
            jira = { command = "mine" }
            """)
        defer { try? FileManager.default.removeItem(at: h.tmp) }

        #expect(h.run() == .skippedUserOwned)
        let toml = try h.toml()
        #expect(toml.contains("jira = { command = \"mine\" }"))
        #expect(toml.contains("[mcp_servers.jira]") == false)
    }

    @Test func unMirrorsWhenSourceRemoved() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)

        try h.writeClaude(jira: nil)
        #expect(h.run() == .removed)

        let toml = try h.toml()
        #expect(toml.contains("[mcp_servers.jira]") == false)
        #expect(h.run() == .noSource)
    }

    @Test func unMirrorPreservesSiblingServers() throws {
        let h = try makeHarness(
            jira: ["command": "uvx"],
            existingToml: """
            [mcp_servers.github]
            command = "npx"
            """)
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)
        try h.writeClaude(jira: nil)
        #expect(h.run() == .removed)
        let toml = try h.toml()
        #expect(toml.contains("[mcp_servers.github]"))
        #expect(toml.contains("command = \"npx\""))
        #expect(toml.contains("[mcp_servers.jira]") == false)
    }

    @Test func doesNotUnMirrorUserAuthoredOnSourceRemoval() throws {
        let h = try makeHarness(existingToml: """
            [mcp_servers.jira]
            command = "mine"
            """)
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try h.writeClaude(jira: nil)
        #expect(h.run() == .skippedUserOwned)
        let toml = try h.toml()
        #expect(toml.contains("command = \"mine\""))
    }

    @Test func deletingEntryIsDurableOptOut() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)

        try "".write(toFile: h.tomlPath, atomically: true, encoding: .utf8)
        #expect(h.run() == .skippedUserOwned)
        #expect(try h.toml().contains("[mcp_servers.jira]") == false)

        try h.writeClaude(jira: nil)
        #expect(h.run() == .noSource)
        try h.writeClaude(jira: ["command": "uvx", "args": ["mcp-atlassian"]])
        #expect(h.run() == .skippedUserOwned)
        #expect(try h.toml().contains("[mcp_servers.jira]") == false)
    }

    @Test func refreshesCrowOwnedTableWhenSourceChanges() throws {
        let h = try makeHarness(jira: ["command": "uvx", "args": ["old"]])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(h.run() == .registered)

        try h.writeClaude(jira: ["command": "uvx", "args": ["new"]])
        #expect(h.run() == .registered)
        let toml = try h.toml()
        #expect(toml.contains("args = [\"new\"]"))
        #expect(toml.contains("args = [\"old\"]") == false)
        #expect(toml.components(separatedBy: "[mcp_servers.jira]").count == 2)
    }

    @Test func claudeHasJiraServerProbesSource() throws {
        let h = try makeHarness(jira: ["command": "uvx"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        #expect(GrokMCPConfigWriter.claudeHasJiraServer(claudeJSONPath: h.claude.path))
        try h.writeClaude(jira: nil)
        #expect(GrokMCPConfigWriter.claudeHasJiraServer(claudeJSONPath: h.claude.path) == false)
        #expect(GrokMCPConfigWriter.claudeHasJiraServer(
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
        #expect(try h.toml().contains("[mcp_servers.jira]"))
    }

    @Test func refusesNonUtf8ConfigToml() throws {
        let h = try makeHarness(jira: ["command": "uvx"])
        defer { try? FileManager.default.removeItem(at: h.tmp) }
        try Data([0xFF, 0xFE, 0x00]).write(to: URL(fileURLWithPath: h.tomlPath))
        #expect(h.run() == .skippedUnparseable)
    }
}
