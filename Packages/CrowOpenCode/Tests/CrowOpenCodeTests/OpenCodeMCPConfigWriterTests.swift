import Foundation
import Testing
@testable import CrowOpenCode

@Suite("OpenCodeMCPConfigWriter")
struct OpenCodeMCPConfigWriterTests {

    // MARK: - Translation

    @Test func translatesClaudeLocalServer() throws {
        let claude: [String: Any] = [
            "command": "uvx",
            "args": ["mcp-atlassian", "--transport", "stdio"],
            "env": ["JIRA_URL": "https://acme.example.net"],
        ]
        let out = try #require(OpenCodeMCPConfigWriter.translateClaudeServer(claude))
        #expect(out["type"] as? String == "local")
        #expect(out["command"] as? [String] == ["uvx", "mcp-atlassian", "--transport", "stdio"])
        #expect(out["enabled"] as? Bool == true)
        let env = try #require(out["environment"] as? [String: Any])
        #expect(env["JIRA_URL"] as? String == "https://acme.example.net")
    }

    @Test func translatesClaudeRemoteServer() throws {
        let claude: [String: Any] = [
            "type": "http",
            "url": "https://mcp.example.net/jira",
            "headers": ["Authorization": "Bearer x"],
        ]
        let out = try #require(OpenCodeMCPConfigWriter.translateClaudeServer(claude))
        #expect(out["type"] as? String == "remote")
        #expect(out["url"] as? String == "https://mcp.example.net/jira")
        #expect(out["enabled"] as? Bool == true)
        let headers = try #require(out["headers"] as? [String: Any])
        #expect(headers["Authorization"] as? String == "Bearer x")
        // Never mislabels a remote server as local.
        #expect(out["command"] == nil)
    }

    @Test func translateReturnsNilForUnusableServer() {
        #expect(OpenCodeMCPConfigWriter.translateClaudeServer(["foo": "bar"]) == nil)
    }

    // MARK: - End-to-end registration

    /// Write a Claude config carrying a `jira` MCP, run the mirror, and return
    /// the parsed `<configHome>/opencode.json`.
    private func runMirror(
        claudeMCPServers: [String: Any]?,
        existingOpenCode: [String: Any]? = nil
    ) throws -> (outcome: OpenCodeMCPConfigWriter.Outcome, root: [String: Any]?) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let claudePath = tmp.appendingPathComponent(".claude.json")
        if let servers = claudeMCPServers {
            let data = try JSONSerialization.data(withJSONObject: ["mcpServers": servers])
            try data.write(to: claudePath)
        }

        let configHome = tmp.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        if let existing = existingOpenCode {
            let data = try JSONSerialization.data(withJSONObject: existing)
            try data.write(to: configHome.appendingPathComponent("opencode.json"))
        }

        let outcome = OpenCodeMCPConfigWriter.installGlobalMCPConfig(
            configHome: configHome.path, claudeJSONPath: claudePath.path)

        let target = configHome.appendingPathComponent("opencode.json")
        let root = FileManager.default.contents(atPath: target.path)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
        return (outcome, root)
    }

    @Test func registersJiraMCPFromClaudeConfig() throws {
        let (outcome, root) = try runMirror(claudeMCPServers: [
            "jira": ["command": "uvx", "args": ["mcp-atlassian"]],
        ])
        #expect(outcome == .registered)
        let mcp = try #require(root?["mcp"] as? [String: Any])
        let jira = try #require(mcp["jira"] as? [String: Any])
        #expect(jira["type"] as? String == "local")
        #expect(jira["command"] as? [String] == ["uvx", "mcp-atlassian"])
        // A fresh file gets the OpenCode schema.
        #expect(root?["$schema"] as? String == "https://opencode.ai/config.json")
    }

    @Test func noOpWhenClaudeHasNoJiraMCP() throws {
        let (outcome, _) = try runMirror(claudeMCPServers: ["other": ["command": "x"]])
        #expect(outcome == .noSource)
    }

    @Test func noOpWhenClaudeConfigMissing() throws {
        let (outcome, _) = try runMirror(claudeMCPServers: nil)
        #expect(outcome == .noSource)
    }

    @Test func mergePreservesExistingOpenCodeKeys() throws {
        let (outcome, root) = try runMirror(
            claudeMCPServers: ["jira": ["command": "uvx", "args": ["mcp-atlassian"]]],
            existingOpenCode: [
                "$schema": "https://opencode.ai/config.json",
                "theme": "opencode",
                "mcp": ["other": ["type": "local", "command": ["x"], "enabled": true]],
            ])
        #expect(outcome == .registered)
        // User's unrelated keys survive.
        #expect(root?["theme"] as? String == "opencode")
        let mcp = try #require(root?["mcp"] as? [String: Any])
        // Both the pre-existing server and the new jira entry are present.
        #expect(mcp["other"] != nil)
        #expect(mcp["jira"] != nil)
    }

    @Test func secondRunIsUnchanged() throws {
        // Registering, then registering again against the same inputs, is idempotent.
        let servers: [String: Any] = ["jira": ["command": "uvx", "args": ["mcp-atlassian"]]]
        let (first, root) = try runMirror(claudeMCPServers: servers)
        #expect(first == .registered)
        let (second, _) = try runMirror(
            claudeMCPServers: servers, existingOpenCode: root)
        #expect(second == .unchanged)
    }

    @Test func refusesToTouchUnparseableOpenCodeConfig() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("opencode-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let claudePath = tmp.appendingPathComponent(".claude.json")
        try JSONSerialization.data(withJSONObject: [
            "mcpServers": ["jira": ["command": "uvx", "args": ["mcp-atlassian"]]],
        ]).write(to: claudePath)

        let configHome = tmp.appendingPathComponent("opencode")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        try "not json {".write(
            to: configHome.appendingPathComponent("opencode.json"),
            atomically: true, encoding: .utf8)

        let outcome = OpenCodeMCPConfigWriter.installGlobalMCPConfig(
            configHome: configHome.path, claudeJSONPath: claudePath.path)
        #expect(outcome == .skippedUnparseable)
    }
}
