import Foundation

/// Registers the Jira MCP server into OpenCode's config so OpenCode sessions
/// get the same `jira_*` tools Claude Code sessions do — parity with Claude
/// (CROW-831).
///
/// **Where the spec comes from.** Post-CROW-528 Crow does *not* provision or
/// store a Jira MCP itself; Claude Code sessions inherit a user-provisioned
/// global `jira` server from `~/.claude.json` (`mcpServers.jira`). So "parity
/// with Claude" here means: mirror *that* server into OpenCode. If the user has
/// no `jira` MCP configured for Claude, this is a no-op — OpenCode gets nothing,
/// exactly as Claude would.
///
/// **Where it's written.** OpenCode merges every global config file it finds —
/// `config.json`, `opencode.json`, **and** `opencode.jsonc`
/// (`config.ts@v1.18.4:258-260`) — so Crow writes a dedicated, Crow-owned
/// `<configHome>/opencode.json`. That keeps us off the user's hand-edited
/// `opencode.jsonc` (whose comments a JSON round-trip would strip) while still
/// being loaded. Scope is **global**, matching the org-wide single-Jira-account
/// model (one `jira` server serves every session).
///
/// The write merges: it preserves `$schema`, any other `mcp` entries, and every
/// other key already in `opencode.json`, and refuses to touch a file that isn't
/// a JSON object. Idempotent — re-running rewrites only the `mcp.jira` entry.
/// It **un-mirrors**: when the source `jira` server disappears from the Claude
/// config, the previously-written `mcp.jira` is dropped so a stale server never
/// lingers. A user's explicit `enabled: false` on the mirrored entry is
/// preserved across launches. The file is written `0600` — the mirrored
/// `environment`/`headers` carry the same secrets `~/.claude.json` (itself
/// `0600`) does.
public enum OpenCodeMCPConfigWriter {

    /// The MCP server name. Matches Claude's `jira` key so the `jira_*` tool
    /// names the prompts reference resolve identically across harnesses.
    static let serverName = "jira"

    public enum Outcome: Equatable {
        /// The `mcp.jira` entry was written/updated in `opencode.json`.
        case registered
        /// The source `jira` server is gone and the previously-mirrored
        /// `mcp.jira` entry was dropped from `opencode.json` (un-mirror).
        case removed
        /// `opencode.json` already carried an identical `mcp.jira`; nothing written.
        case unchanged
        /// No `jira` MCP server in the Claude config to mirror, and nothing
        /// stale to remove; nothing written.
        case noSource
        /// A target/source file exists but isn't a JSON object; refused to touch it.
        case skippedUnparseable
        /// Read or write failed.
        case failed(String)
    }

    /// Mirror the user's Claude `jira` MCP into `<configHome>/opencode.json`.
    /// Pass `claudeJSONPath` to read a different Claude config (tests); `nil`
    /// uses the real `~/.claude.json`.
    ///
    /// Lifecycle parity with Claude (CROW-831 review): when the source `jira`
    /// server *disappears* from the Claude config, the previously-mirrored
    /// `mcp.jira` is removed from `opencode.json` too — so a stale (and possibly
    /// credential-bearing) server never lingers after the user drops it from
    /// Claude. Crow owns the `mcp.jira` key in this file; user-authored MCP
    /// servers belong in `opencode.jsonc` (or under a different name).
    @discardableResult
    public static func installGlobalMCPConfig(
        configHome: String,
        claudeJSONPath: String? = nil
    ) -> Outcome {
        let fm = FileManager.default

        // 1. Read the source `jira` server from the Claude config. Distinguish
        //    "absent" (→ un-mirror) from "present but untranslatable" (→ leave
        //    the mirror alone) from "unparseable" (→ refuse).
        let claudePath = claudeJSONPath
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path
        let sourceServer: [String: Any]?
        switch readClaudeJiraServer(claudeJSONPath: claudePath) {
        case .success(let server): sourceServer = server
        case .unparseable: return .skippedUnparseable
        }

        // 2. Load the Crow-owned `opencode.json` (if any).
        let targetPath = (configHome as NSString).appendingPathComponent("opencode.json")
        let targetExists = fm.fileExists(atPath: targetPath)
        var root: [String: Any] = ["$schema": "https://opencode.ai/config.json"]
        if targetExists {
            guard let data = fm.contents(atPath: targetPath),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                NSLog("[OpenCodeMCPConfigWriter] %@ exists but is not a JSON object; refusing to modify it", targetPath)
                return .skippedUnparseable
            }
            root = parsed
        }
        var mcp = root["mcp"] as? [String: Any] ?? [:]

        // 3a. Source gone → drop any stale mirror we wrote.
        guard let sourceServer, let translated = translateClaudeServer(sourceServer) else {
            guard mcp[serverName] != nil else { return .noSource }
            mcp.removeValue(forKey: serverName)
            if mcp.isEmpty {
                root.removeValue(forKey: "mcp")
            } else {
                root["mcp"] = mcp
            }
            return write(root, to: targetPath, configHome: configHome, fm: fm) ?? .removed
        }

        // 3b. Source present → register/update. Preserve a user's explicit
        //     `enabled` value so disabling the mirror in `opencode.json` sticks
        //     across launches (we only ever *default* it to true on first write).
        var openCodeServer = translated
        if let existing = mcp[serverName] as? [String: Any],
           let userEnabled = existing["enabled"] {
            openCodeServer["enabled"] = userEnabled
        }
        if let existing = mcp[serverName] as? [String: Any],
           NSDictionary(dictionary: existing).isEqual(to: openCodeServer) {
            return .unchanged
        }
        mcp[serverName] = openCodeServer
        root["mcp"] = mcp
        return write(root, to: targetPath, configHome: configHome, fm: fm) ?? .registered
    }

    /// Write `root` as pretty JSON to `path`, owner-only. `mcp.<name>` mirrors
    /// Claude's `environment`/`headers`, which carry secrets (e.g. a Jira API
    /// token), and `~/.claude.json` is `0600` — so match it. `.atomic` renames a
    /// fresh temp file over the target, resetting its mode to the umask default
    /// (~`0644`), so the `setAttributes` is required, not belt-and-braces
    /// (`Scaffolder.swift:177`, `ClaudeHookConfigWriter.writeGatewayEnv:147`).
    /// Returns `.failed` on error, or `nil` on success (the caller supplies the
    /// success outcome).
    private static func write(
        _ root: [String: Any],
        to path: String,
        configHome: String,
        fm: FileManager
    ) -> Outcome? {
        do {
            try fm.createDirectory(atPath: configHome, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return nil
        } catch {
            NSLog("[OpenCodeMCPConfigWriter] Failed to write %@: %@", path, error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Source

    enum ClaudeReadResult {
        case success([String: Any]?)
        case unparseable
    }

    /// The `mcpServers.jira` object from `~/.claude.json`, or `nil` when absent.
    /// A file that exists but isn't a JSON object is reported as `.unparseable`
    /// so the caller refuses to proceed (rather than silently overwriting).
    static func readClaudeJiraServer(claudeJSONPath: String) -> ClaudeReadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeJSONPath) else { return .success(nil) }
        guard let data = fm.contents(atPath: claudeJSONPath),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            NSLog("[OpenCodeMCPConfigWriter] %@ exists but is not a JSON object; ignoring", claudeJSONPath)
            return .unparseable
        }
        let servers = root["mcpServers"] as? [String: Any]
        return .success(servers?[serverName] as? [String: Any])
    }

    // MARK: - Translation

    /// Translate a Claude Code MCP server object into OpenCode's `mcp` entry
    /// shape. Returns `nil` when the source has neither a `url` (remote) nor a
    /// `command` (local) — i.e. nothing we can faithfully mirror.
    ///
    /// Claude local:  `{ command: "uvx", args: [...], env: {...} }`
    ///   → OpenCode:  `{ type: "local", command: ["uvx", ...args], environment: {...}, enabled: true }`
    /// Claude remote: `{ type: "http"|"sse", url: "...", headers: {...} }`
    ///   → OpenCode:  `{ type: "remote", url: "...", headers: {...}, enabled: true }`
    static func translateClaudeServer(_ server: [String: Any]) -> [String: Any]? {
        let claudeType = (server["type"] as? String)?.lowercased()
        let isRemote = server["url"] is String
            && (claudeType == "http" || claudeType == "sse" || server["command"] == nil)

        if isRemote, let url = server["url"] as? String {
            var out: [String: Any] = ["type": "remote", "url": url, "enabled": true]
            if let headers = server["headers"] as? [String: Any], !headers.isEmpty {
                out["headers"] = headers
            }
            return out
        }

        if let command = server["command"] as? String {
            var argv: [String] = [command]
            if let args = server["args"] as? [String] {
                argv.append(contentsOf: args)
            } else if let args = server["args"] as? [Any] {
                argv.append(contentsOf: args.compactMap { $0 as? String })
            }
            var out: [String: Any] = ["type": "local", "command": argv, "enabled": true]
            if let env = server["env"] as? [String: Any], !env.isEmpty {
                out["environment"] = env
            }
            return out
        }

        return nil
    }
}
