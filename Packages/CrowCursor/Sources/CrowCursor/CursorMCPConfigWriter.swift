import Foundation

/// Bridges the user's `jira` MCP server — the one configured for Claude Code
/// in `~/.claude.json` under `mcpServers` — into Cursor's `~/.cursor/mcp.json`
/// so Cursor sessions inherit the same Jira MCP (#829).
///
/// **Why a file bridge, not a CLI call.** The audited Cursor build
/// (`agent 2026.07.23`) has no `cursor-agent mcp add`: the `mcp` subcommand
/// only exposes `login`/`list`/`list-tools`/`enable`/`disable`, and servers are
/// declared in `.cursor/mcp.json` / `~/.cursor/mcp.json` (as the `login` help
/// text itself states). So we mirror the file, not run a command.
///
/// **What "reuse the config already written for Claude" means.** Crow no longer
/// provisions a Jira MCP itself (CROW-528 removed that — Claude sessions
/// inherit the user's global `~/.claude.json` entry). The only Jira MCP config
/// that exists to reuse is therefore the user's own, so we read it from
/// `~/.claude.json` and copy just the `jira` server into Cursor's config,
/// merge-preserving any other Cursor MCP servers. When the user hasn't
/// configured a Jira MCP for Claude, this is a no-op.
///
/// Cursor and Claude use the identical `mcpServers` entry schema
/// (`{command, args, env}` or `{url, type}`), so the entry copies verbatim.
public enum CursorMCPConfigWriter {
    /// The server key we bridge — matches the `jira` MCP the `CursorLauncher`
    /// / `ClaudeLauncher` prompts reference (`jira_get_issue`, `jira_*`).
    static let serverKey = "jira"

    /// Copy the `jira` server from Claude's `mcpServers` into Cursor's
    /// `mcp.json`. Idempotent — skips the write (and the 0600 re-apply) when
    /// the bridged entry already matches. Paths are injectable for tests;
    /// `nil` uses the real `~/.claude.json` / `~/.cursor/mcp.json`.
    public static func bridgeJiraMCP(
        claudeJSONPath: String? = nil,
        cursorMCPPath: String? = nil
    ) {
        let claudePath = claudeJSONPath ?? home(".claude.json")
        let cursorPath = cursorMCPPath ?? home(".cursor/mcp.json")

        // Source: the jira server def from Claude's config. Absent → no-op.
        guard let claudeData = FileManager.default.contents(atPath: claudePath),
              let claudeRoot = try? JSONSerialization.jsonObject(with: claudeData) as? [String: Any],
              let claudeServers = claudeRoot["mcpServers"] as? [String: Any],
              let jiraEntry = claudeServers[serverKey] as? [String: Any] else {
            return
        }

        // Destination: merge into Cursor's mcp.json, preserving other servers.
        var root: [String: Any] = [:]
        if let existing = FileManager.default.contents(atPath: cursorPath),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]

        // Idempotent: bail if the bridged entry is already identical.
        if let current = servers[serverKey] as? [String: Any],
           NSDictionary(dictionary: current).isEqual(to: jiraEntry) {
            return
        }
        servers[serverKey] = jiraEntry
        root["mcpServers"] = servers

        do {
            let dir = (cursorPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: cursorPath))
            // An MCP server entry's `env` can carry a token — restrict the file
            // to owner-only, matching how Crow guards `~/.claude.json` and
            // `settings.local.json`.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: cursorPath)
        } catch {
            NSLog("[CursorMCPConfigWriter] Failed to bridge jira MCP to %@: %@",
                  cursorPath, error.localizedDescription)
        }
    }

    private static func home(_ relative: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative).path
    }
}
