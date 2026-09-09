import CrowCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Mirrors the user's Claude `jira` MCP server into Muse Code's user-scope
/// settings (`<$XDG_CONFIG_HOME or ~/.config>/muse/settings.json`
/// `mcp_servers.jira`) so a Muse session gets the same `jira_*` tools
/// Claude/Cursor/Grok/Antigravity do (CROW-1209 — Phase A leftover from #1033).
///
/// **Where the spec comes from.** Post-CROW-528 Crow does *not* provision a
/// Jira MCP itself; Claude sessions inherit a user-provisioned `jira` server
/// from `~/.claude.json`. So "parity with Claude" means: copy *that* server
/// into Muse. No `jira` in Claude's config → no-op.
///
/// **Where it's written.** Official Muse docs (Configuration and context +
/// Extending and automating, confirmed 2026-09-08) name the user-scope file as
/// `~/.config/muse/settings.json` (`mcp_servers`). Session journals live under
/// `MuseHome.path()` (`$XDG_DATA_HOME/muse`) — a different tree. Crow does not
/// write a project-scope MCP file; review clones still strip `.muse/` +
/// `.agents/` so an attacker-controlled project layer cannot land.
///
/// Schema (official extending docs): each server takes `transport` — `stdio`
/// (`command` / `args` / `env`) or `streamable_http` (`url` / `headers`) — plus
/// `enabled` and `mode`. `mode` defaults to `required`, which **aborts the
/// whole run** if the server fails to start; Crow writes `mode: "optional"` so
/// a down Jira MCP logs a warning instead of bricking the session (the prompt
/// still names `acli` as fallback). `settings.json` **must** set
/// `"schema_version": 1` or every `muse` command fails at startup with
/// `malformed settings file`. A missing file is fine (Muse applies defaults);
/// Crow always includes `schema_version: 1` when creating or rewriting, and
/// never overwrites an existing version key.
///
/// **When it runs.** Launch-gated, not daemon boot — same reason as Cursor
/// (#829) / Grok (CROW-1205) / Antigravity (CROW-1207): do not copy the token
/// onto a box that merely has `muse` on PATH. Callers dispatch off the main
/// actor (possibly-large `~/.claude.json`).
///
/// **Merge-preserving.** `settings.json` is Muse's own user file (model,
/// hooks, other `mcp_servers`, UI prefs). A user-authored `jira` entry is
/// never overwritten. Crow keeps a sidecar recording the exact entry it last
/// wrote (`~/.local/share/crow/muse-mcp-mirror.json`, `0600`) and only
/// refreshes or un-mirrors when the on-disk entry still matches that record.
/// Editing or deleting the entry makes it "not ours".
///
/// **Un-mirror.** When `~/.claude.json` parses cleanly with no `jira`, an
/// entry Crow wrote is dropped so a stale credential-bearing server never
/// lingers. A missing/unreadable source is left alone (a torn read must not
/// reap). Both the config and the sidecar are written `0600` via POSIX
/// `rename(2)` so Linux is safe and the token is never group/other-readable.
/// Crow never deletes `settings.json` itself — unlike Antigravity's
/// MCP-only `mcp_config.json`, this is Muse's whole user file.
public enum MuseMCPConfigWriter {

    /// Matches Claude's `jira` key so the `jira_*` tool names the prompts
    /// reference resolve identically across harnesses.
    static let serverName = "jira"

    /// Muse's required top-level settings schema. Omitting it bricks every
    /// `muse` command (`malformed settings file`).
    static let schemaVersion = 1

    public enum Outcome: Equatable {
        /// `mcp_servers.jira` was written/updated in `settings.json`.
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

    /// Mirror into Muse's default config home. Convenience for launch sites
    /// that don't override paths.
    public static func bridgeJiraMCPDefault() {
        _ = installMCPConfig(configHome: MuseHome.configHome())
    }

    /// Serializes the read-modify-write of the one global `settings.json`
    /// against concurrent bridges from parallel launches.
    private static let writeLock = NSLock()

    /// Mirror the user's Claude `jira` MCP into `<configHome>/settings.json`.
    /// Pass `claudeJSONPath` / `mirrorRecordPath` to redirect the source and
    /// the provenance sidecar (tests); `nil` uses `~/.claude.json` and
    /// `~/.local/share/crow/muse-mcp-mirror.json`.
    @discardableResult
    public static func installMCPConfig(
        configHome: String,
        claudeJSONPath: String? = nil,
        mirrorRecordPath: String? = nil
    ) -> Outcome {
        writeLock.lock()
        defer { writeLock.unlock() }

        let claudePath = claudeJSONPath ?? ClaudeMCPSource.defaultPath()

        let sourceServer: [String: Any]?
        switch ClaudeMCPSource.lookupJira(from: claudePath) {
        case .found(let entry, origin: let origin):
            if case .project(let key) = origin {
                CrowLog.info("[MuseMCPConfigWriter] Promoting project-scoped `jira` MCP from \(key) into global Muse settings.json")
            }
            sourceServer = entry
        case .absent:
            sourceServer = nil
        case .sourceUnavailable:
            CrowLog.info("[MuseMCPConfigWriter] \(claudePath) missing/unreadable; leaving Muse settings.json untouched")
            return .noSource
        case .unparseable:
            CrowLog.info("[MuseMCPConfigWriter] \(claudePath) exists but is not a JSON object; ignoring")
            return .skippedUnparseable
        }

        let targetPath = (configHome as NSString).appendingPathComponent("settings.json")
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: targetPath) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                CrowLog.info("[MuseMCPConfigWriter] \(targetPath) exists but is not a JSON object; refusing to modify it")
                return .skippedUnparseable
            }
            root = parsed
        }
        if root["mcp_servers"] != nil, (root["mcp_servers"] as? [String: Any]) == nil {
            CrowLog.info("[MuseMCPConfigWriter] \(targetPath) mcp_servers is not a JSON object; refusing to modify it")
            return .skippedUnparseable
        }
        var servers = root["mcp_servers"] as? [String: Any] ?? [:]
        let existing = servers[serverName] as? [String: Any]

        let recordPath = mirrorRecordPath ?? defaultMirrorRecordPath()
        var record = readMirrorRecord(path: recordPath)
        let recorded = record[serverName] as? [String: Any]
        let entryIsOurs = existing != nil && recorded != nil && jsonEqual(existing!, recorded!)

        // Source absent → un-mirror, but only an entry we actually wrote.
        if sourceServer == nil {
            guard existing != nil else { return .noSource }
            guard entryIsOurs else {
                CrowLog.info("[MuseMCPConfigWriter] mcp_servers.\(serverName) not written by Crow; leaving it alone")
                return .skippedUserOwned
            }
            servers.removeValue(forKey: serverName)
            if servers.isEmpty {
                root.removeValue(forKey: "mcp_servers")
            } else {
                root["mcp_servers"] = servers
            }
            ensureSchemaVersion(&root)
            if let failure = writeJSON(root, to: targetPath, configHome: configHome, fm: fm) {
                return failure
            }
            record.removeValue(forKey: serverName)
            writeMirrorRecord(record, path: recordPath, fm: fm)
            return .removed
        }

        guard let translated = translateClaudeServer(sourceServer!) else {
            CrowLog.info("[MuseMCPConfigWriter] Claude mcpServers.\(serverName) present but not translatable; leaving Muse config unchanged")
            return .noSource
        }

        // Durable opt-out: the user deleted an entry Crow wrote (entry gone,
        // record still present). Don't re-add it.
        if existing == nil, recorded != nil {
            CrowLog.info("[MuseMCPConfigWriter] mcp_servers.\(serverName) removed after Crow wrote it; honoring the opt-out")
            return .skippedUserOwned
        }

        // Never clobber a user-authored entry (or the user's edits to ours).
        if existing != nil, !entryIsOurs {
            let why = recorded == nil
                ? "no Crow record for it (user-authored, or the mirror sidecar was lost)"
                : "it differs from Crow's record (user-edited)"
            CrowLog.info("[MuseMCPConfigWriter] mcp_servers.\(serverName) left as-is — \(why); not overwriting")
            return .skippedUserOwned
        }

        if let existing, jsonEqual(existing, translated) {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetPath)
            return .unchanged
        }

        servers[serverName] = translated
        root["mcp_servers"] = servers
        ensureSchemaVersion(&root)
        if let failure = writeJSON(root, to: targetPath, configHome: configHome, fm: fm) {
            return failure
        }
        record[serverName] = translated
        writeMirrorRecord(record, path: recordPath, fm: fm)
        return .registered
    }

    /// Whether `~/.claude.json` (or `claudeJSONPath`) declares a `jira` MCP
    /// server Crow can mirror. Used by `MuseLauncher` so the seed prompt names
    /// `jira_*` only when a bridge is expected; a Muse-primary host with no
    /// Claude Jira MCP keeps the `acli` arm.
    public static func claudeHasJiraServer(claudeJSONPath: String? = nil) -> Bool {
        if case .found(let entry, origin: _) = ClaudeMCPSource.lookupJira(from: claudeJSONPath) {
            return translateClaudeServer(entry) != nil
        }
        return false
    }

    // MARK: - Translation

    /// Translate one Claude `mcpServers.<name>` definition into Muse's
    /// `mcp_servers` entry. Returns `nil` when the definition has neither
    /// `command` nor a remote URL. Stdio copies `command`/`args`/`env` and
    /// sets `transport: "stdio"`; remote Claude `url` / Gemini-legacy
    /// `httpUrl` become `transport: "streamable_http"` plus `url`/`headers`.
    /// `mode` is always `"optional"` so a failed Jira MCP does not abort the
    /// Muse run (official default is `required`).
    static func translateClaudeServer(_ def: [String: Any]) -> [String: Any]? {
        let command = (def["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let remoteURL = firstNonEmptyString(def, keys: ["url", "httpUrl", "serverUrl"])

        if let command {
            var out: [String: Any] = [
                "transport": "stdio",
                "command": command,
                "mode": "optional",
            ]
            let args = (def["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            if !args.isEmpty { out["args"] = args }
            if let env = stringifyMap(def["env"] as? [String: Any]), !env.isEmpty {
                out["env"] = env
            }
            return out
        }
        if let remoteURL {
            var out: [String: Any] = [
                "transport": "streamable_http",
                "url": remoteURL,
                "mode": "optional",
            ]
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
            .appendingPathComponent(".local/share/crow/muse-mcp-mirror.json").path
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
            CrowLog.info("[MuseMCPConfigWriter] Failed to write mirror record \(path): \(error.localizedDescription)")
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
            CrowLog.info("[MuseMCPConfigWriter] Failed to write \(path): \(error.localizedDescription)")
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
        let tmp = (dir as NSString).appendingPathComponent(".crow-muse-mcp-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            CrowLog.info("[MuseMCPConfigWriter] Failed to create temp for \(path)")
            return false
        }
        let renamed = tmp.withCString { tmpC in
            path.withCString { pathC in rename(tmpC, pathC) == 0 }
        }
        if !renamed {
            CrowLog.info("[MuseMCPConfigWriter] atomic rename to \(path) failed (errno \(errno))")
            try? fm.removeItem(atPath: tmp)
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// Inject `"schema_version": 1` when missing. Never overwrites an existing
    /// version *value* — an unrecognized value already fails Muse startup, and
    /// Crow must not "upgrade" a file it doesn't own.
    ///
    /// JSONSerialization round-trips integers as `NSNumber`, and an `NSNumber`
    /// of `1` can re-encode as JSON `true` (`objCType` `"c"`). Coerce any
    /// numeric value back to a Swift `Int` so Muse's required numeric
    /// `schema_version` survives a rewrite.
    static func ensureSchemaVersion(_ root: inout [String: Any]) {
        if let n = root["schema_version"] as? NSNumber {
            root["schema_version"] = n.intValue
        } else if root["schema_version"] == nil {
            root["schema_version"] = schemaVersion
        }
    }

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
