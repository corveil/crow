import Foundation

/// Mirrors the user's Claude Code MCP servers into Codex so a Codex session
/// gets the same tools (e.g. the `jira` MCP) that a Claude session inherits
/// from `~/.claude.json` (#830 — "MCP parity with Claude's `~/.claude.json`").
///
/// Crow deliberately does **not** provision any MCP of its own (CROW-528): the
/// user configures `mcpServers` in `~/.claude.json` and Crow simply reflects
/// that configuration into Codex's `[mcp_servers.*]` tables in
/// `~/.codex/config.toml`. When Claude has no MCPs configured this is a no-op.
///
/// **Append-only, never clobber.** Codex's `config.toml` is the user's own
/// state (model, providers, credentials, trusted projects, `[hooks]`), and a
/// user may have already hand-tuned an `[mcp_servers.<name>]` block. So this
/// only *adds* servers whose table is absent, and never rewrites or deletes an
/// existing one — the safe posture for a credentials-bearing file. To force a
/// refresh after changing a server in `~/.claude.json`, remove it from
/// `~/.codex/config.toml` (or `codex mcp remove <name>`) and relaunch.
public enum CodexMCPWriter {

    /// A translated MCP server ready to serialize as a Codex `[mcp_servers.*]`
    /// table. Either `command` (stdio transport) or `url` (streamable HTTP) is
    /// set; a definition carrying neither is skipped upstream.
    struct Server {
        var name: String
        var command: String?
        var args: [String]
        var env: [(String, String)]  // ordered for deterministic output
        var url: String?
    }

    // MARK: - Public install

    /// Read `mcpServers` from `claudeJSONPath` (default `~/.claude.json`) and
    /// append a `[mcp_servers.<name>]` table to `<codexHome>/config.toml` for
    /// every server not already present there. Returns the names that were
    /// newly added (empty when nothing to mirror or all already present).
    ///
    /// Idempotent: a second run adds nothing because every server is now
    /// present. Never throws on a missing/unparseable `~/.claude.json` — that
    /// just means "no MCPs to mirror".
    @discardableResult
    public static func installMCPConfig(
        codexHome: String,
        claudeJSONPath: String? = nil
    ) throws -> [String] {
        let servers = readClaudeServers(claudeJSONPath: claudeJSONPath)
        guard !servers.isEmpty else { return [] }

        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        let tomlPath = (codexHome as NSString).appendingPathComponent("config.toml")

        var content = ""
        if let data = FileManager.default.contents(atPath: tomlPath),
           let text = String(data: data, encoding: .utf8) {
            content = text
        }

        var added: [String] = []
        for server in servers where !content.contains(sectionHeaderVariants(server.name)) {
            content = appendServerBlock(content, server: server)
            added.append(server.name)
        }
        guard !added.isEmpty else { return [] }

        try content.write(toFile: tomlPath, atomically: true, encoding: .utf8)
        // config.toml can carry provider credentials — keep it owner-only.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tomlPath)
        return added
    }

    // MARK: - Claude parsing

    /// Parse `~/.claude.json`'s `mcpServers` object into translated `Server`s,
    /// dropping any definition Codex can't express (neither `command` nor
    /// `url`). Server order follows JSON key order sorted for determinism.
    static func readClaudeServers(claudeJSONPath: String?) -> [Server] {
        let path = claudeJSONPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json").path
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let mcp = root["mcpServers"] as? [String: Any]
        else { return [] }

        var servers: [Server] = []
        for name in mcp.keys.sorted() {
            guard let def = mcp[name] as? [String: Any],
                  let server = translate(name: name, def: def) else { continue }
            servers.append(server)
        }
        return servers
    }

    /// Translate one Claude `mcpServers.<name>` definition into a `Server`.
    /// Returns `nil` when the definition has no usable transport.
    static func translate(name: String, def: [String: Any]) -> Server? {
        let command = (def["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let url = (def["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        let args = (def["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        var env: [(String, String)] = []
        if let envDict = def["env"] as? [String: Any] {
            for key in envDict.keys.sorted() {
                if let value = stringify(envDict[key]) { env.append((key, value)) }
            }
        }

        if command != nil {
            return Server(name: name, command: command, args: args, env: env, url: nil)
        }
        if url != nil {
            // Streamable-HTTP server: Codex uses `url`. Arbitrary Claude
            // `headers` don't map to Codex's `url`-only HTTP form (it takes a
            // bearer-token env var, not free-form headers), so they're dropped.
            return Server(name: name, command: nil, args: [], env: env, url: url)
        }
        return nil
    }

    // MARK: - TOML generation

    /// Append a fresh `[mcp_servers.<name>]` table (preceded by a blank-line
    /// separator) to `content`. Assumes the caller already checked the table is
    /// absent.
    static func appendServerBlock(_ content: String, server: Server) -> String {
        var out = content
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        out += serverBlock(server)
        return out
    }

    /// Render a single `[mcp_servers.<name>]` table (no leading/trailing blank
    /// lines). Pure — the unit under test.
    static func serverBlock(_ server: Server) -> String {
        var lines: [String] = ["[mcp_servers.\(keyToken(server.name))]"]
        if let command = server.command {
            lines.append("command = \"\(escape(command))\"")
            if !server.args.isEmpty {
                let items = server.args.map { "\"\(escape($0))\"" }.joined(separator: ", ")
                lines.append("args = [\(items)]")
            }
        } else if let url = server.url {
            lines.append("url = \"\(escape(url))\"")
        }
        if !server.env.isEmpty {
            let pairs = server.env
                .map { "\(keyToken($0.0)) = \"\(escape($0.1))\"" }
                .joined(separator: ", ")
            lines.append("env = { \(pairs) }")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The header spellings we treat as "already present" so we never duplicate
    /// a server the user (or a prior run) already wrote. Covers bare and quoted
    /// keys; the `.contains` in `installMCPConfig` uses the canonical form we'd
    /// emit, and TOML normalizes `foo` and `"foo"` identically.
    private static func sectionHeaderVariants(_ name: String) -> String {
        "[mcp_servers.\(keyToken(name))]"
    }

    /// A TOML key: bare when it matches `[A-Za-z0-9_-]+`, otherwise
    /// double-quoted-and-escaped. MCP/env names are normally bare (`jira`,
    /// `JIRA_API_TOKEN`).
    static func keyToken(_ key: String) -> String {
        let bare = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        return (bare && !key.isEmpty) ? key : "\"\(escape(key))\""
    }

    private static func escape(_ s: String) -> String {
        CodexHookConfigWriter.escapeTomlString(s)
    }

    private static func stringify(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let i as Int: return String(i)
        case let b as Bool: return String(b)
        case let d as Double: return String(d)
        default: return nil
        }
    }
}
