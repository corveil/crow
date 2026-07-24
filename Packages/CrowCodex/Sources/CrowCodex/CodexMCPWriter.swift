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
///
/// **Scope (deliberately narrow):**
/// - Only **root-level** `mcpServers` are mirrored. Claude's project-scoped
///   `projects.<path>.mcpServers` are not (they'd need per-worktree Codex
///   config, which the per-worktree-hooks deferral already parks).
/// - Mirroring runs only at daemon boot (from `LaunchScaffold`). A server added
///   to `~/.claude.json` mid-session doesn't reach Codex until the next daemon
///   restart.
/// - HTTP servers carrying `headers` (auth) are skipped, and `env` values are
///   copied verbatim (Codex doesn't expand `${VAR}`) — see `translate`.
///
/// **Concurrency.** `config.toml` is read-modify-written here, in
/// `CodexHookConfigWriter.installGlobalTomlConfig`, and in `CodexTrustSeeder`
/// with no shared lock. In practice the mirror and the toml-config install both
/// run once, synchronously, from `LaunchScaffold` at boot — before any session
/// launch's `seedTrust` — so they don't interleave today. A future caller that
/// seeds trust concurrently with a boot mirror could lose one write (re-run on
/// the next boot fixes it); worth knowing before adding an out-of-band writer.
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
        for server in servers where !serverAlreadyPresent(content, name: server.name) {
            content = appendServerBlock(content, server: server)
            added.append(server.name)
        }
        guard !added.isEmpty else { return [] }

        // config.toml can carry provider credentials (and the mirrored `env`
        // values are themselves secrets) — write via the owner-only-temp path so
        // nothing lands in a 0644 temp mid-rename.
        try CodexHookConfigWriter.writeConfigPrivately(content, toFile: tomlPath)
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
    /// Returns `nil` when the definition has no usable transport, or when it's
    /// an HTTP server carrying `headers` — Claude puts an HTTP MCP's
    /// `Authorization` there, and Codex's `url` form can't express arbitrary
    /// headers (only a bearer-token env var), so mirroring it would ship an
    /// **auth-less** server that silently fails to connect. Skipping fails
    /// louder (#843 review round 3).
    ///
    /// Note on `env`: values are copied **verbatim**. Claude Code expands
    /// `${VAR}` / `${VAR:-default}` inside `env` values; Codex does not — so a
    /// Claude config that uses that indirection mirrors the literal `${VAR}`
    /// string (harmless: the secret was never in `~/.claude.json` to copy, and
    /// the resulting server is simply non-functional until fixed by hand).
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
            // HTTP/SSE server. If it carries `headers` (where the auth lives),
            // we can't faithfully mirror it — skip rather than write a broken
            // auth-less entry.
            if let headers = def["headers"] as? [String: Any], !headers.isEmpty {
                return nil
            }
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

    /// Whether `content` already declares an MCP server named `name`, so we
    /// never append a duplicate (TOML rejects a redefined table / duplicate key
    /// — the same unparseable-config outcome the escaping guards against, and
    /// append-only means it never self-heals). Recognizes every spelling Codex
    /// accepts, via the comment/whitespace/quote-tolerant `tomlHeaderSegments`:
    /// - the bare or quoted dotted table header `[mcp_servers.jira]` /
    ///   `[mcp_servers."jira"]`, with or without a trailing `# comment` or
    ///   whitespace around the dots (`[mcp_servers . jira]`);
    /// - a sub-table header `[mcp_servers.jira.env]`;
    /// - an inline key inside a bare `[mcp_servers]` parent table (`jira = { … }`).
    ///
    /// A fully `#`-commented header reads as absent (and gets mirrored) rather
    /// than silently dropped. (Not covered: a top-level dotted-key assignment
    /// `mcp_servers.jira.command = …` with no header — rare; `codex mcp add`
    /// emits the header form.)
    static func serverAlreadyPresent(_ content: String, name: String) -> Bool {
        var inParentTable = false
        for raw in content.components(separatedBy: "\n") {
            if let segments = CodexHookConfigWriter.tomlHeaderSegments(raw) {
                // Header: match `[mcp_servers.<name>]` and any sub-table under it.
                if segments.count >= 2, segments[0] == "mcp_servers", segments[1] == name {
                    return true
                }
                inParentTable = (segments == ["mcp_servers"])
                continue
            }
            if inParentTable {
                let bare = CodexHookConfigWriter.stripTomlInlineComment(raw)
                    .trimmingCharacters(in: .whitespaces)
                if bare.isEmpty { continue }
                if assignmentKey(of: bare) == name { return true }
            }
        }
        return false
    }

    /// The (unquoted) key of a `key = value` TOML assignment, or `nil` for a
    /// non-assignment line. Handles a quoted key (`"jira" = …`). Splits on the
    /// first `=` so an inline-table value (`jira = { command = … }`) yields
    /// `jira`, not `command`.
    private static func assignmentKey(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let raw = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    /// A TOML key: **ASCII** bare when it matches `[A-Za-z0-9_-]+`, otherwise
    /// double-quoted-and-escaped. TOML bare keys are ASCII-only, so a Unicode
    /// letter/digit (`café`, `٣`) must be quoted — `Character.isLetter` /
    /// `isNumber` are Unicode-aware and would wrongly bare them. MCP/env names
    /// are normally already bare (`jira`, `JIRA_API_TOKEN`).
    static func keyToken(_ key: String) -> String {
        let bare = !key.isEmpty && key.allSatisfy { c in
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z")
                || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
        return bare ? key : "\"\(escape(key))\""
    }

    private static func escape(_ s: String) -> String {
        CodexHookConfigWriter.escapeTomlString(s)
    }

    private static func stringify(_ value: Any?) -> String? {
        switch value {
        // Bool MUST precede Int: `JSONSerialization` bridges booleans as
        // `NSNumber`, so a `true`/`false` would otherwise match `as Int` and
        // stringify to "1"/"0" instead of "true"/"false" (#843 review round 4).
        case let b as Bool: return String(b)
        case let i as Int: return String(i)
        case let s as String: return s
        case let d as Double: return String(d)
        default: return nil
        }
    }
}
