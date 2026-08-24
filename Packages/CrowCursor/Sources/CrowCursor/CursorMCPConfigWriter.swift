import CrowCore
import Foundation
#if canImport(Glibc)
import Glibc  // POSIX `rename`/`errno` on Linux (Darwin re-exports them via Foundation on macOS)
#endif

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
/// **User and local scopes are searched.** `claude mcp add`'s default scope is
/// **local**, stored under `projects[<path>].mcpServers`; only `-s user` writes
/// the root `mcpServers` block. We prefer the root (user) entry and fall back to
/// the first project-scoped `jira` we find, so the common default-scope case
/// isn't missed. (Claude's third scope — a repo's committed `.mcp.json` — is not
/// read; nothing bridged from it means nothing to reap, so it's harmless.) When
/// no Jira MCP is found we log and no-op.
///
/// Cursor and Claude use the identical `mcpServers` entry schema
/// (`{command, args, env}` or `{url, type}`), so the entry copies verbatim.
public enum CursorMCPConfigWriter {
    /// The server key we bridge — matches the `jira` MCP the `CursorLauncher`
    /// / `ClaudeLauncher` prompts reference (`jira_get_issue`, `jira_*`).
    static let serverKey = "jira"

    /// Bridge into Cursor's default `mcp.json` — `<CURSOR_CONFIG_DIR>/mcp.json`,
    /// or `~/.cursor/mcp.json`. Convenience for launch sites that don't override
    /// paths. Callers on the main actor should dispatch this off-main (it reads
    /// a possibly-large `~/.claude.json`); the write is global and self-heals on
    /// the next launch, so fire-and-forget is fine.
    public static func bridgeJiraMCPDefault() {
        // Resolve the Cursor home through the shared `CursorHome` resolver (honors
        // `$CURSOR_CONFIG_DIR`, empty-is-unset) — one source of truth with the
        // session-log collector's chats path (CROW-1095).
        let cursorHome = CursorHome.path()
        bridgeJiraMCP(cursorMCPPath: (cursorHome as NSString).appendingPathComponent("mcp.json"))
    }

    /// Marker recording which servers Crow bridged, so a later run can tell
    /// Crow's own bridge (safe to refresh) from a user's hand-authored `jira`
    /// server (never touch). Kept as a **top-level** array — *not* a foreign key
    /// inside the server entry — so the `jira` definition Cursor parses stays
    /// byte-identical to Claude's, with zero risk of a strict parser rejecting
    /// it.
    static let managedKey = "x-crow-managed"

    /// Serializes the read-modify-write of the one global `~/.cursor/mcp.json`
    /// against concurrent bridges from parallel launches.
    private static let writeLock = NSLock()

    /// Atomically write `root` as pretty JSON to `path`, owner-only. The
    /// content is written to a sibling temp created **`0600` up front**, then
    /// atomically renamed over the destination — so the token-bearing `env` is
    /// never group/other-readable at any instant (a plain `Data.write(.atomic)`
    /// would create the new file `0644` per umask, exposing the token until a
    /// follow-up chmod).
    ///
    /// Uses POSIX `rename(2)` rather than `FileManager.replaceItemAt` /
    /// `moveItem`: `replaceItemAt` is unreliable on swift-corelibs-foundation
    /// (Linux — throws "file doesn't exist" when replacing) and `moveItem`
    /// refuses to overwrite; `rename` is atomic, portable, replaces an existing
    /// destination, and keeps the temp inode's `0600`.
    private static func atomicWriteJSON(_ root: [String: Any], to path: String) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])

            let tmp = (dir as NSString).appendingPathComponent(".crow-mcp-\(UUID().uuidString).tmp")
            guard FileManager.default.createFile(
                atPath: tmp, contents: out, attributes: [.posixPermissions: 0o600]) else {
                CrowLog.info("[CursorMCPConfigWriter] Failed to create temp for \(path)")
                return
            }
            if rename(tmp, path) != 0 {
                CrowLog.info("[CursorMCPConfigWriter] atomic rename to \(path) failed (errno \(errno))")
                try? FileManager.default.removeItem(atPath: tmp)
            }
        } catch {
            CrowLog.info("[CursorMCPConfigWriter] Failed to write \(path): \(error.localizedDescription)")
        }
    }

    /// Copy the `jira` server from Claude's config into Cursor's `mcp.json`.
    ///
    /// **Never clobbers a user's own `jira` server.** `~/.cursor/mcp.json` is as
    /// user-owned as `.cursor/hooks.json`, and this runs at every launch, so a
    /// bare overwrite would repeatedly stomp a user who configured Cursor's Jira
    /// MCP differently (e.g. a remote `http` server vs Claude's local stdio).
    /// We only write when the `jira` slot is absent or listed in our top-level
    /// `x-crow-managed` marker; a user-authored entry is left in place and
    /// logged.
    ///
    /// Idempotent — skips the content write when the bridged entry already
    /// matches, but still tightens permissions. Paths are injectable for tests;
    /// `nil` uses the real `~/.claude.json` / `~/.cursor/mcp.json`.
    public static func bridgeJiraMCP(
        claudeJSONPath: String? = nil,
        cursorMCPPath: String? = nil
    ) {
        let claudePath = claudeJSONPath ?? home(".claude.json")
        let cursorPath = cursorMCPPath ?? home(".cursor/mcp.json")

        // Serialize the whole read-modify-write: the bridge fires unsynchronized
        // from several launch paths (and `/crow-batch-workspace` parallelizes
        // setup), so two bridges racing on this one global file is a normal flow.
        writeLock.lock()
        defer { writeLock.unlock() }

        // Source: the jira server def from Claude's config. Distinguish "the
        // user removed jira" (parsed fine, none present → reap our copy) from
        // "couldn't read/parse" (missing / transient IO / truncated 2.1 MB live
        // file → do NOT touch cursor's config, or a bad read would delete a
        // valid bridged entry).
        let jiraEntry: [String: Any]
        switch readClaudeJira(claudeJSONPath: claudePath) {
        case .found(let entry):
            jiraEntry = entry
        case .absent:
            reapManagedJira(cursorMCPPath: cursorPath)
            return
        case .sourceUnavailable:
            CrowLog.info("[CursorMCPConfigWriter] \(claudePath) missing/unreadable; leaving ~/.cursor/mcp.json untouched")
            return
        }

        // Destination: merge into Cursor's mcp.json, preserving other servers.
        // Mirror the source-side guard — if the file EXISTS but doesn't parse
        // (a torn concurrent write, a hand-edit with JSONC/syntax error), bail
        // rather than start from `[:]` and clobber every other MCP server the
        // user configured.
        var root: [String: Any] = [:]
        if let existing = FileManager.default.contents(atPath: cursorPath) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                CrowLog.info("[CursorMCPConfigWriter] \(cursorPath) exists but is unparseable; leaving it untouched (would otherwise drop the user's other MCP servers)")
                return
            }
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        var managed = Set(root[managedKey] as? [String] ?? [])

        if let current = servers[serverKey] as? [String: Any] {
            if !managed.contains(serverKey) {
                CrowLog.info("[CursorMCPConfigWriter] \(cursorPath) already has a user-authored `jira` MCP server; leaving it untouched")
                return
            }
            if NSDictionary(dictionary: current).isEqual(to: jiraEntry) {
                // Already up to date; still tighten perms in case the file was
                // created world-readable before.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: cursorPath)
                return
            }
        }

        servers[serverKey] = jiraEntry
        managed.insert(serverKey)
        root["mcpServers"] = servers
        root[managedKey] = managed.sorted()
        atomicWriteJSON(root, to: cursorPath)
    }

    /// Remove a `jira` server we previously bridged (recorded in the top-level
    /// `x-crow-managed` marker) from Cursor's `mcp.json`. No-op when the file is
    /// absent, has no `jira`, or the `jira` there is user-authored (unmarked).
    private static func reapManagedJira(cursorMCPPath: String) {
        guard let data = FileManager.default.contents(atPath: cursorMCPPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var managed = Set(root[managedKey] as? [String] ?? [])
        guard managed.contains(serverKey),
              var servers = root["mcpServers"] as? [String: Any],
              servers[serverKey] != nil else {
            return
        }
        servers.removeValue(forKey: serverKey)
        managed.remove(serverKey)
        if servers.isEmpty { root.removeValue(forKey: "mcpServers") } else { root["mcpServers"] = servers }
        if managed.isEmpty { root.removeValue(forKey: managedKey) } else { root[managedKey] = managed.sorted() }

        if root.isEmpty {
            try? FileManager.default.removeItem(atPath: cursorMCPPath)
        } else {
            atomicWriteJSON(root, to: cursorMCPPath)
        }
        CrowLog.info("[CursorMCPConfigWriter] Reaped bridged `jira` MCP from \(cursorMCPPath) — no longer in Claude's config")
    }

    /// Outcome of looking for a `jira` server in Claude's config.
    private enum ClaudeJiraLookup {
        /// Found a `jira` server (user or project scope).
        case found([String: Any])
        /// `~/.claude.json` parsed cleanly but declares no `jira` anywhere —
        /// the only signal that means "the user removed it" (safe to reap).
        case absent
        /// Missing, unreadable, or unparseable — do not act; a transient read
        /// failure must not trigger a destructive reap.
        case sourceUnavailable
    }

    /// Look for a `jira` server in Claude's config: root `mcpServers` (user
    /// scope) preferred, else `projects[<path>].mcpServers` (local scope,
    /// Claude's default). Project keys are scanned in **sorted** order so which
    /// server wins is deterministic when multiple projects declare `jira`.
    ///
    /// Note the scope widening: a *project-local* Claude MCP is promoted into
    /// Cursor's *global* `~/.cursor/mcp.json`, so a token scoped to one repo
    /// becomes available to every Cursor session on the machine — the tradeoff
    /// for MCP reachability across worktrees.
    private static func readClaudeJira(claudeJSONPath: String) -> ClaudeJiraLookup {
        guard let data = FileManager.default.contents(atPath: claudeJSONPath) else {
            return .sourceUnavailable  // missing or unreadable
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .sourceUnavailable  // unparseable (e.g. truncated/interleaved read)
        }
        if let userScoped = (root["mcpServers"] as? [String: Any])?[serverKey] as? [String: Any] {
            return .found(userScoped)
        }
        if let projects = root["projects"] as? [String: Any] {
            for key in projects.keys.sorted() {
                if let servers = (projects[key] as? [String: Any])?["mcpServers"] as? [String: Any],
                   let jira = servers[serverKey] as? [String: Any] {
                    // Visibility: a project-scoped Claude MCP token is about to
                    // be promoted into Cursor's *global* config (every session).
                    CrowLog.info("[CursorMCPConfigWriter] Promoting project-scoped `jira` MCP from \(key) into global ~/.cursor/mcp.json")
                    return .found(jira)
                }
            }
        }
        return .absent  // parsed fine, no jira in any scope
    }

    private static func home(_ relative: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relative).path
    }
}
