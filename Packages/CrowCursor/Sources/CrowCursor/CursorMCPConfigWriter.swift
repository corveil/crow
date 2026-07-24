import Foundation

/// Bridges the user's `jira` MCP server — the one configured for Claude Code
/// in `~/.claude.json` — into Cursor's `~/.cursor/mcp.json` so Cursor sessions
/// inherit the same Jira MCP (#829).
///
/// **Why a file bridge, not a CLI call.** The audited Cursor build
/// (`agent 2026.07.23`) has no `cursor-agent mcp add`: the `mcp` subcommand
/// only exposes `login`/`list`/`list-tools`/`enable`/`disable`, and servers are
/// declared in `.cursor/mcp.json` / `~/.cursor/mcp.json` (as the `login` help
/// text itself states). So we mirror the file, not run a command.
///
/// **What "reuse the config already written for Claude" means.** Crow no longer
/// provisions a Jira MCP itself (CROW-528 removed that — Claude sessions
/// inherit the user's own `~/.claude.json` entry). The only Jira MCP config
/// that exists to reuse is therefore the user's own, so we read it and copy
/// just the `jira` server into Cursor's config, merge-preserving any other
/// Cursor MCP servers.
///
/// **Both Claude scopes are searched.** `claude mcp add`'s default scope is
/// **local**, stored under `projects[<path>].mcpServers`; only `-s user` writes
/// the root `mcpServers` block. We prefer the root (user) entry and fall back to
/// the first project-scoped `jira` we find, so the common default-scope case
/// isn't missed. When no Jira MCP is configured in either scope we log and
/// no-op.
///
/// Cursor and Claude use the identical `mcpServers` entry schema
/// (`{command, args, env}` or `{url, type}`), so the entry copies verbatim.
public enum CursorMCPConfigWriter {
    /// The server key we bridge — matches the `jira` MCP the `CursorLauncher`
    /// / `ClaudeLauncher` prompts reference (`jira_get_issue`, `jira_*`).
    static let serverKey = "jira"

    /// Copy the `jira` server from Claude's config into Cursor's `mcp.json`.
    /// Idempotent — skips the content write when the bridged entry already
    /// matches, but still tightens permissions on a pre-existing file. Paths
    /// are injectable for tests; `nil` uses the real `~/.claude.json` /
    /// `~/.cursor/mcp.json`.
    public static func bridgeJiraMCP(
        claudeJSONPath: String? = nil,
        cursorMCPPath: String? = nil
    ) {
        let claudePath = claudeJSONPath ?? home(".claude.json")
        let cursorPath = cursorMCPPath ?? home(".cursor/mcp.json")

        // Source: the jira server def from Claude's config, checking user scope
        // (root `mcpServers`) first, then any project-local scope.
        guard let jiraEntry = readClaudeJiraEntry(claudeJSONPath: claudePath) else {
            NSLog("[CursorMCPConfigWriter] No `jira` MCP server found in %@ (root or project scope); nothing to bridge", claudePath)
            return
        }

        // Destination: merge into Cursor's mcp.json, preserving other servers.
        var root: [String: Any] = [:]
        if let existing = FileManager.default.contents(atPath: cursorPath),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]

        let alreadyBridged = (servers[serverKey] as? [String: Any])
            .map { NSDictionary(dictionary: $0).isEqual(to: jiraEntry) } ?? false

        if !alreadyBridged {
            servers[serverKey] = jiraEntry
            root["mcpServers"] = servers
            do {
                let dir = (cursorPath as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let out = try JSONSerialization.data(
                    withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
                try out.write(to: URL(fileURLWithPath: cursorPath))
            } catch {
                NSLog("[CursorMCPConfigWriter] Failed to bridge jira MCP to %@: %@",
                      cursorPath, error.localizedDescription)
                return
            }
        }

        // An MCP server entry's `env` can carry a token — restrict the file to
        // owner-only, matching how Crow guards `~/.claude.json` and
        // `settings.local.json`. Applied even when the content was already
        // bridged, so a pre-existing world-readable file still gets tightened.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: cursorPath)
    }

    /// The `jira` server definition from Claude's config: root `mcpServers`
    /// (user scope) preferred, else the first `projects[<path>].mcpServers`
    /// (local scope, Claude's default) that has one. `nil` when neither exists.
    private static func readClaudeJiraEntry(claudeJSONPath: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: claudeJSONPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let userScoped = (root["mcpServers"] as? [String: Any])?[serverKey] as? [String: Any] {
            return userScoped
        }
        // Local scope: scan every project's mcpServers for a jira entry.
        guard let projects = root["projects"] as? [String: Any] else { return nil }
        for (_, value) in projects {
            if let servers = (value as? [String: Any])?["mcpServers"] as? [String: Any],
               let jira = servers[serverKey] as? [String: Any] {
                return jira
            }
        }
        return nil
    }

    private static func home(_ relative: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative).path
    }
}
