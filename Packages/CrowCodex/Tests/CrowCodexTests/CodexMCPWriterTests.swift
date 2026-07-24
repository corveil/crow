import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("CodexMCPWriter")
struct CodexMCPWriterTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Block generation (pure)

    @Test func serverBlockStdio() {
        let server = CodexMCPWriter.Server(
            name: "jira",
            command: "npx",
            args: ["-y", "@atlassian/mcp"],
            env: [("JIRA_TOKEN", "abc123")],
            url: nil
        )
        let block = CodexMCPWriter.serverBlock(server)
        #expect(block.contains("[mcp_servers.jira]"))
        #expect(block.contains("command = \"npx\""))
        #expect(block.contains("args = [\"-y\", \"@atlassian/mcp\"]"))
        #expect(block.contains("env = { JIRA_TOKEN = \"abc123\" }"))
        #expect(!block.contains("url ="))
    }

    @Test func serverBlockHTTP() {
        let server = CodexMCPWriter.Server(
            name: "remote", command: nil, args: [], env: [], url: "https://mcp.example.com")
        let block = CodexMCPWriter.serverBlock(server)
        #expect(block.contains("[mcp_servers.remote]"))
        #expect(block.contains("url = \"https://mcp.example.com\""))
        #expect(!block.contains("command ="))
    }

    @Test func serverBlockEscapesAndQuotesKeys() {
        let server = CodexMCPWriter.Server(
            name: "my server",  // non-bare → quoted table key
            command: "sh",
            args: ["-c", "echo \"hi\""],
            env: [("PATH_VAR", "/a\\b")],
            url: nil
        )
        let block = CodexMCPWriter.serverBlock(server)
        #expect(block.contains("[mcp_servers.\"my server\"]"))
        // Backslash and quote escaped in values.
        #expect(block.contains("\"echo \\\"hi\\\"\""))
        #expect(block.contains("/a\\\\b"))
    }

    // MARK: - Translation

    @Test func translateStdioAndHTTPAndSkipsUnusable() {
        let stdio = CodexMCPWriter.translate(
            name: "jira", def: ["command": "npx", "args": ["-y", "x"], "env": ["K": "v"]])
        #expect(stdio?.command == "npx")
        #expect(stdio?.args == ["-y", "x"])
        #expect(stdio?.env.first?.0 == "K")

        let http = CodexMCPWriter.translate(name: "r", def: ["type": "http", "url": "https://h"])
        #expect(http?.url == "https://h")
        #expect(http?.command == nil)

        // Neither command nor url → not expressible in Codex → skipped.
        #expect(CodexMCPWriter.translate(name: "bad", def: ["type": "sse"]) == nil)
    }

    // MARK: - Install

    private func writeClaudeJSON(_ dir: URL, _ mcpServers: [String: Any]) throws -> String {
        let path = dir.appendingPathComponent("claude.json").path
        let root: [String: Any] = ["mcpServers": mcpServers]
        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test func installMirrorsFromClaudeJSON() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let claudePath = try writeClaudeJSON(dir, [
            "jira": ["command": "npx", "args": ["-y", "@atlassian/mcp"], "env": ["JIRA_TOKEN": "t"]],
            "remote": ["type": "http", "url": "https://mcp.example.com"],
        ])

        let added = try CodexMCPWriter.installMCPConfig(codexHome: dir.path, claudeJSONPath: claudePath)
        #expect(added.sorted() == ["jira", "remote"])

        let toml = try String(contentsOf: dir.appendingPathComponent("config.toml"))
        #expect(toml.contains("[mcp_servers.jira]"))
        #expect(toml.contains("command = \"npx\""))
        #expect(toml.contains("[mcp_servers.remote]"))
        #expect(toml.contains("url = \"https://mcp.example.com\""))
    }

    @Test func installIsAppendOnlyAndPreservesExisting() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-seed config.toml with credentials + a user-customized jira server.
        let existing = """
        model = "gpt-5.5"

        [model_providers.corveil]
        api_key = "sk-secret"

        [mcp_servers.jira]
        command = "/custom/user/jira-mcp"
        """
        try existing.write(
            toFile: dir.appendingPathComponent("config.toml").path,
            atomically: true, encoding: .utf8)

        let claudePath = try writeClaudeJSON(dir, [
            "jira": ["command": "npx", "args": ["-y", "@atlassian/mcp"]],
            "github": ["command": "gh-mcp"],
        ])

        let added = try CodexMCPWriter.installMCPConfig(codexHome: dir.path, claudeJSONPath: claudePath)
        // jira already present → not touched; only github added.
        #expect(added == ["github"])

        let toml = try String(contentsOf: dir.appendingPathComponent("config.toml"))
        // Credentials + user's custom jira command survive untouched.
        #expect(toml.contains("api_key = \"sk-secret\""))
        #expect(toml.contains("command = \"/custom/user/jira-mcp\""))
        #expect(!toml.contains("@atlassian/mcp"), "existing jira must not be overwritten")
        // github appended.
        #expect(toml.contains("[mcp_servers.github]"))
        #expect(toml.contains("command = \"gh-mcp\""))
    }

    @Test func installNoOpWhenNoMCPServers() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let claudePath = dir.appendingPathComponent("claude.json").path
        try JSONSerialization.data(withJSONObject: ["oauthAccount": ["x": "y"]])
            .write(to: URL(fileURLWithPath: claudePath))

        let added = try CodexMCPWriter.installMCPConfig(codexHome: dir.path, claudeJSONPath: claudePath)
        #expect(added.isEmpty)
        // No config.toml created for a no-op mirror.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.toml").path))
    }

    @Test func installIsIdempotent() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let claudePath = try writeClaudeJSON(dir, ["jira": ["command": "npx", "args": ["-y", "x"]]])

        let first = try CodexMCPWriter.installMCPConfig(codexHome: dir.path, claudeJSONPath: claudePath)
        #expect(first == ["jira"])
        let afterFirst = try String(contentsOf: dir.appendingPathComponent("config.toml"))

        let second = try CodexMCPWriter.installMCPConfig(codexHome: dir.path, claudeJSONPath: claudePath)
        #expect(second.isEmpty)
        let afterSecond = try String(contentsOf: dir.appendingPathComponent("config.toml"))
        #expect(afterFirst == afterSecond)
    }

    @Test func installNoOpWhenClaudeJSONMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let added = try CodexMCPWriter.installMCPConfig(
            codexHome: dir.path,
            claudeJSONPath: dir.appendingPathComponent("does-not-exist.json").path)
        #expect(added.isEmpty)
    }
}
