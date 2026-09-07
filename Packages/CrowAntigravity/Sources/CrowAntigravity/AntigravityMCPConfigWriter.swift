import CrowCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Mirrors the user's Claude `jira` MCP server into Antigravity's user-scope
/// MCP file (`<$GEMINI_CONFIG_HOME or ~/.gemini/config>/mcp_config.json`
/// `mcpServers.jira`) so an Antigravity session gets the same `jira_*` tools
/// Claude/Cursor/Grok do (CROW-1207 — Phase A leftover from #860).
///
/// **Where the spec comes from.** Post-CROW-528 Crow does *not* provision a
/// Jira MCP itself; Claude sessions inherit a user-provisioned `jira` server
/// from `~/.claude.json`. So "parity with Claude" means: copy *that* server
/// into Antigravity. No `jira` in Claude's config → no-op.
///
/// **Where it's written.** Official Antigravity MCP docs name the user-scope
/// file as `~/.gemini/config/mcp_config.json` (workspace-local
/// `.agents/mcp_config.json` is a different surface — Crow does not write it,
/// and review clones still strip `.agents/` so an attacker-controlled project
/// MCP cannot land). `$GEMINI_CONFIG_HOME` is honored when set and non-empty,
/// matching `LaunchScaffold`'s hooks cleanup path. Schema is Claude-like
/// `mcpServers` with one Antigravity-specific rename: remote servers use
/// `serverUrl` (not Claude's `url` / Gemini-legacy `httpUrl`).
///
/// **When it runs.** Launch-gated, not daemon boot — same reason as Cursor
/// (#829) / Grok (CROW-1205): do not copy the token onto a box that merely
/// has `agy` on PATH. Callers dispatch off the main actor (possibly-large
/// `~/.claude.json`).
///
/// **Merge-preserving.** `mcp_config.json` is Antigravity's own user file
/// (other `mcpServers`, IDE/CLI customizations). A user-authored `jira` entry
/// is never overwritten. Crow keeps a sidecar recording the exact entry it
/// last wrote (`~/.local/share/crow/antigravity-mcp-mirror.json`, `0600`) and
/// only refreshes or un-mirrors when the on-disk entry still matches that
/// record. Editing or deleting the entry makes it "not ours".
///
/// **Un-mirror.** When `~/.claude.json` parses cleanly with no `jira`, an
/// entry Crow wrote is dropped so a stale credential-bearing server never
/// lingers. A missing/unreadable source is left alone (a torn read must not
/// reap). Both the config and the sidecar are written `0600` via POSIX
/// `rename(2)` so Linux is safe and the token is never group/other-readable.
public enum AntigravityMCPConfigWriter {

    /// Matches Claude's `jira` key so the `jira_*` tool names the prompts
    /// reference resolve identically across harnesses.
    static let serverName = "jira"

    public enum Outcome: Equatable {
        /// `mcpServers.jira` was written/updated in `mcp_config.json`.
        case registered
        /// The source `jira` is gone and the previously-mirrored entry was dropped.
        case removed
        /// The on-disk entry already matched the source; nothing written.
        case unchanged
        /// A `jira` entry exists that Crow did not write (user-authored, or one
        /// the user has since edited/deleted); left untouched.
        case skippedUserOwned
        /// No `jira` MCP in the Claude config to mirror, and nothing stale to remove.
        case noSource
        /// A target/source file exists but isn't usable; refused to touch it.
        case skippedUnparseable
        /// Read or write failed.
        case failed(String)
    }

    /// Mirror into Antigravity's default config home. Convenience for launch
    /// sites that don't override paths.
    public static func bridgeJiraMCPDefault() {
        _ = installMCPConfig(configHome: AntigravityHome.configHome())
    }

    /// Serializes the read-modify-write of the one global `mcp_config.json`
    /// against concurrent bridges from parallel launches.
    private static let writeLock = NSLock()

    /// Mirror the user's Claude `jira` MCP into `<configHome>/mcp_config.json`.
    /// Pass `claudeJSONPath` / `mirrorRecordPath` to redirect the source and
    /// the provenance sidecar (tests); `nil` uses `~/.claude.json` and
    /// `~/.local/share/crow/antigravity-mcp-mirror.json`.
    @discardableResult
    public static func installMCPConfig(
        configHome: String,
        claudeJSONPath: String? = nil,
        mirrorRecordPath: String? = nil
    ) -> Outcome {
        writeLock.lock()
        defer { writeLock.unlock() }

        let claudePath = claudeJSONPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json").path

        let sourceServer: [String: Any]?
        switch readClaudeJira(claudeJSONPath: claudePath) {
        case .found(let entry):
            sourceServer = entry
        case .absent:
            sourceServer = nil
        case .sourceUnavailable:
            CrowLog.info("[AntigravityMCPConfigWriter] \(claudePath) missing/unreadable; leaving Antigravity mcp_config.json untouched")
            return .noSource
        case .unparseable:
            return .skippedUnparseable
        }

        let targetPath = (configHome as NSString).appendingPathComponent("mcp_config.json")
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: targetPath) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                CrowLog.info("[AntigravityMCPConfigWriter] \(targetPath) exists but is not a JSON object; refusing to modify it")
                return .skippedUnparseable
            }
            root = parsed
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        let existing = servers[serverName] as? [String: Any]

        let recordPath = mirrorRecordPath ?? defaultMirrorRecordPath()
        var record = readMirrorRecord(path: recordPath)
        let recorded = record[serverName] as? [String: Any]
        let entryIsOurs = existing != nil && recorded != nil && jsonEqual(existing!, recorded!)

        // Source absent → un-mirror, but only an entry we actually wrote.
        if sourceServer == nil {
            guard existing != nil else { return .noSource }
            guard entryIsOurs else {
                CrowLog.info("[AntigravityMCPConfigWriter] mcpServers.\(serverName) not written by Crow; leaving it alone")
                return .skippedUserOwned
            }
            servers.removeValue(forKey: serverName)
            if servers.isEmpty {
                root.removeValue(forKey: "mcpServers")
            } else {
                root["mcpServers"] = servers
            }
            if root.isEmpty {
                try? fm.removeItem(atPath: targetPath)
            } else if let failure = writeJSON(root, to: targetPath, configHome: configHome, fm: fm) {
                return failure
            }
            record.removeValue(forKey: serverName)
            writeMirrorRecord(record, path: recordPath, fm: fm)
            return .removed
        }

        guard let translated = translateClaudeServer(sourceServer!) else {
            CrowLog.info("[AntigravityMCPConfigWriter] Claude mcpServers.\(serverName) present but not translatable; leaving Antigravity config unchanged")
            return .noSource
        }

        // Durable opt-out: the user deleted an entry Crow wrote (entry gone,
        // record still present). Don't re-add it.
        if existing == nil, recorded != nil {
            CrowLog.info("[AntigravityMCPConfigWriter] mcpServers.\(serverName) removed after Crow wrote it; honoring the opt-out")
            return .skippedUserOwned
        }

        // Never clobber a user-authored entry (or the user's edits to ours).
        if existing != nil, !entryIsOurs {
            let why = recorded == nil
                ? "no Crow record for it (user-authored, or the mirror sidecar was lost)"
                : "it differs from Crow's record (user-edited)"
            CrowLog.info("[AntigravityMCPConfigWriter] mcpServers.\(serverName) left as-is — \(why); not overwriting")
            return .skippedUserOwned
        }

        if let existing, jsonEqual(existing, translated) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetPath)
            return .unchanged
        }

        servers[serverName] = translated
        root["mcpServers"] = servers
        if let failure = writeJSON(root, to: targetPath, configHome: configHome, fm: fm) {
            return failure
        }
        record[serverName] = translated
        writeMirrorRecord(record, path: recordPath, fm: fm)
        return .registered
    }

    /// Whether `~/.claude.json` (or `claudeJSONPath`) declares a `jira` MCP
    /// server Crow can mirror. Used by `AntigravityLauncher` so the seed prompt
    /// names `jira_*` only when a bridge is expected; an Antigravity-primary
    /// host with no Claude Jira MCP keeps the `acli` arm.
    public static func claudeHasJiraServer(claudeJSONPath: String? = nil) -> Bool {
        let path = claudeJSONPath
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude.json").path
        if case .found(let entry) = readClaudeJira(claudeJSONPath: path) {
            return translateClaudeServer(entry) != nil
        }
        return false
    }

    // MARK: - Source

    enum ClaudeJiraLookup {
        case found([String: Any])
        /// Parsed cleanly but declares no `jira` — safe to un-mirror.
        case absent
        /// Missing or unreadable — do not act.
        case sourceUnavailable
        /// Exists but isn't a JSON object.
        case unparseable
    }

    /// Root `mcpServers` (user scope) preferred, else the first project-scoped
    /// `jira` in sorted `projects[<path>].mcpServers` order — same widening
    /// Cursor uses so Claude's default local-scope `mcp add` isn't missed.
    static func readClaudeJira(claudeJSONPath: String) -> ClaudeJiraLookup {
        guard let data = FileManager.default.contents(atPath: claudeJSONPath) else {
            return .sourceUnavailable
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            CrowLog.info("[AntigravityMCPConfigWriter] \(claudeJSONPath) exists but is not a JSON object; ignoring")
            return .unparseable
        }
        if let userScoped = (root["mcpServers"] as? [String: Any])?[serverName] as? [String: Any] {
            return .found(userScoped)
        }
        if let projects = root["projects"] as? [String: Any] {
            for key in projects.keys.sorted() {
                if let servers = (projects[key] as? [String: Any])?["mcpServers"] as? [String: Any],
                   let jira = servers[serverName] as? [String: Any] {
                    CrowLog.info("[AntigravityMCPConfigWriter] Promoting project-scoped `jira` MCP from \(key) into global mcp_config.json")
                    return .found(jira)
                }
            }
        }
        return .absent
    }

    // MARK: - Translation

    /// Translate one Claude `mcpServers.<name>` definition into Antigravity's
    /// `mcpServers` entry. Returns `nil` when the definition has neither
    /// `command` nor a remote URL. Stdio copies `command`/`args`/`env`/`cwd`
    /// verbatim; remote Claude `url` / Gemini-legacy `httpUrl` become
    /// Antigravity's `serverUrl` (plus `headers`).
    static func translateClaudeServer(_ def: [String: Any]) -> [String: Any]? {
        let command = (def["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let remoteURL = firstNonEmptyString(def, keys: ["serverUrl", "url", "httpUrl"])

        if let command {
            var out: [String: Any] = ["command": command]
            let args = (def["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !args.isEmpty { out["args"] = args }
            if let env = stringifyMap(def["env"] as? [String: Any]), !env.isEmpty {
                out["env"] = env
            }
            if let cwd = (def["cwd"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                out["cwd"] = cwd
            }
            return out
        }
        if let remoteURL {
            var out: [String: Any] = ["serverUrl": remoteURL]
            if let headers = stringifyMap(def["headers"] as? [String: Any]), !headers.isEmpty {
                out["headers"] = headers
            }
            return out
        }
        return nil
    }

    // MARK: - Provenance record

    static func defaultMirrorRecordPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow/antigravity-mcp-mirror.json").path
    }

    static func readMirrorRecord(path: String) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return root
    }

    static func writeMirrorRecord(_ record: [String: Any], path: String, fm: FileManager) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            _ = writePrivately(data, to: path)
        } catch {
            CrowLog.info("[AntigravityMCPConfigWriter] Failed to write mirror record \(path): \(error.localizedDescription)")
        }
    }

    // MARK: - Atomic owner-only write

    private static func writeJSON(
        _ root: [String: Any],
        to path: String,
        configHome: String,
        fm: FileManager
    ) -> Outcome? {
        do {
            try fm.createDirectory(atPath: configHome, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            guard writePrivately(data, to: path) else {
                return .failed("atomic write to \(path) failed")
            }
            return nil
        } catch {
            CrowLog.info("[AntigravityMCPConfigWriter] Failed to write \(path): \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Stage a sibling temp created `0600`, then POSIX `rename(2)` over the
    /// destination — never a 0644 umask window, and `replaceItemAt` is
    /// unreliable on swift-corelibs-foundation (Linux).
    @discardableResult
    static func writePrivately(_ data: Data, to path: String) -> Bool {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".crow-agy-mcp-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            CrowLog.info("[AntigravityMCPConfigWriter] Failed to create temp for \(path)")
            return false
        }
        let renamed = tmp.withCString { tmpC in
            path.withCString { pathC in rename(tmpC, pathC) == 0 }
        }
        if !renamed {
            CrowLog.info("[AntigravityMCPConfigWriter] atomic rename to \(path) failed (errno \(errno))")
            try? fm.removeItem(atPath: tmp)
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// Structural equality via canonical JSON bytes — `NSDictionary.isEqual`
    /// does not deep-equate a Swift `[String]` against a JSON-decoded `NSArray`
    /// on swift-corelibs-foundation (Linux CI).
    static func jsonEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        else { return false }
        return da == db
    }

    private static func firstNonEmptyString(_ def: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = (def[key] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
                return value
            }
        }
        return nil
    }

    private static func stringifyMap(_ dict: [String: Any]?) -> [String: String]? {
        guard let dict, !dict.isEmpty else { return nil }
        var out: [String: String] = [:]
        for key in dict.keys.sorted() {
            if let value = stringify(dict[key]) { out[key] = value }
        }
        return out.isEmpty ? nil : out
    }

    private static func stringify(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let num = value as? NSNumber {
            switch String(cString: num.objCType) {
            case "c": return num.boolValue ? "true" : "false"
            case "d", "f": return String(num.doubleValue)
            default: return num.stringValue
            }
        }
        return nil
    }
}
