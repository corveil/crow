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

    @Test func translateSkipsHTTPServerCarryingHeaders() {
        // Claude puts an HTTP MCP's auth in `headers`, which Codex's url form
        // can't express — mirroring would ship an auth-less server, so skip.
        let withAuth = CodexMCPWriter.translate(
            name: "remote",
            def: ["type": "http", "url": "https://h", "headers": ["Authorization": "Bearer x"]])
        #expect(withAuth == nil)
        // …but an HTTP server with no headers is fine to mirror.
        let noAuth = CodexMCPWriter.translate(name: "remote", def: ["url": "https://h"])
        #expect(noAuth?.url == "https://h")
    }

    @Test func serverAlreadyPresentMatchesInlineParentTable() {
        // `[mcp_servers]` with an inline `jira = { … }` key is a valid, distinct
        // spelling — appending `[mcp_servers.jira]` on top would be a duplicate
        // key and break the file.
        let inlineBare = "[mcp_servers]\njira = { command = \"x\" }\n"
        #expect(CodexMCPWriter.serverAlreadyPresent(inlineBare, name: "jira") == true)

        let inlineQuoted = "[mcp_servers]\n\"jira\" = { command = \"x\" }\n"
        #expect(CodexMCPWriter.serverAlreadyPresent(inlineQuoted, name: "jira") == true)

        // A different inline key doesn't count as present.
        #expect(CodexMCPWriter.serverAlreadyPresent(inlineBare, name: "github") == false)

        // An assignment outside the [mcp_servers] table must not match.
        let elsewhere = "[other]\njira = { command = \"x\" }\n"
        #expect(CodexMCPWriter.serverAlreadyPresent(elsewhere, name: "jira") == false)
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

    @Test func serverBlockEscapesControlCharsInEnvValue() {
        // A newline in an env value (PEM key, pretty-printed JSON) must be
        // escaped — a raw newline terminates the TOML basic string and corrupts
        // config.toml (#830 review). The whole server block is a table, so the
        // env value lives on one physical line.
        let server = CodexMCPWriter.Server(
            name: "creds", command: "sh", args: [],
            env: [("PEM", "-----BEGIN-----\nline2\ttab")], url: nil)
        let block = CodexMCPWriter.serverBlock(server)
        #expect(block.contains("-----BEGIN-----\\nline2\\ttab"))  // escaped
        // The `env = { … }` line carries no raw newline/tab.
        let envLine = block.split(separator: "\n").first { $0.contains("env = {") }
        #expect(envLine != nil)
        #expect(envLine?.contains("\t") == false)
    }

    @Test func keyTokenQuotesNonASCII() {
        #expect(CodexMCPWriter.keyToken("jira") == "jira")
        #expect(CodexMCPWriter.keyToken("JIRA_API_TOKEN") == "JIRA_API_TOKEN")
        #expect(CodexMCPWriter.keyToken("gh-mcp") == "gh-mcp")
        // Unicode letters/digits are NOT valid TOML bare keys → must be quoted.
        #expect(CodexMCPWriter.keyToken("café") == "\"café\"")
        #expect(CodexMCPWriter.keyToken("has space") == "\"has space\"")
    }

    @Test func serverAlreadyPresentMatchesQuotedHeaderAndSkipsComments() {
        let quoted = "[mcp_servers.\"jira\"]\ncommand = \"x\""
        #expect(CodexMCPWriter.serverAlreadyPresent(quoted, name: "jira") == true)

        let bare = "[mcp_servers.jira]\ncommand = \"x\""
        #expect(CodexMCPWriter.serverAlreadyPresent(bare, name: "jira") == true)

        // A commented-out header reads as absent (so it gets mirrored, not
        // silently dropped by a substring match).
        let commented = "# [mcp_servers.jira]\n"
        #expect(CodexMCPWriter.serverAlreadyPresent(commented, name: "jira") == false)

        #expect(CodexMCPWriter.serverAlreadyPresent("model = \"x\"", name: "jira") == false)
    }

    @Test func installDoesNotDuplicateQuotedExistingServer() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // User wrote the quoted spelling — a substring check would miss it and
        // append a duplicate `[mcp_servers.jira]`, which TOML rejects.
        try "[mcp_servers.\"jira\"]\ncommand = \"/user/jira\"\n".write(
            toFile: dir.appendingPathComponent("config.toml").path,
            atomically: true, encoding: .utf8)

        let claudePath = try writeClaudeJSON(dir, ["jira": ["command": "npx", "args": ["-y", "x"]]])
        let added = try CodexMCPWriter.installMCPConfig(codexHome: dir.path, claudeJSONPath: claudePath)
        #expect(added.isEmpty, "quoted-header server must be recognized as present")

        let toml = try String(contentsOf: dir.appendingPathComponent("config.toml"))
        #expect(toml.contains("command = \"/user/jira\""))
        #expect(!toml.contains("npx"), "must not append a duplicate jira table")
    }

    @Test func installWritesOwnerOnlyConfig() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let claudePath = try writeClaudeJSON(dir, ["jira": ["command": "npx", "env": ["T": "secret"]]])
        _ = try CodexMCPWriter.installMCPConfig(codexHome: dir.path, claudeJSONPath: claudePath)

        let perms = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("config.toml").path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600, "secrets file must be owner-only")
        // And no stray temp left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".crow-codex-") }
        #expect(leftovers.isEmpty)
    }
}
