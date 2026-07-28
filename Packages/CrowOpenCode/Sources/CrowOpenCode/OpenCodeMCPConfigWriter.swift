import CrowCore
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
///
/// **Provenance (CROW-831 review round 2).** `~/.config/opencode/opencode.json`
/// is OpenCode's own documented global config path — exactly where an
/// OpenCode-primary user's hand-configured `jira` server (or `opencode mcp add`)
/// already lands. So Crow keeps a sidecar recording the exact entry it last
/// wrote (`~/.local/share/crow/opencode-mcp-mirror.json`, `0600`) and only ever
/// touches `mcp.jira` when the on-disk entry still matches that record. A
/// user-authored `jira` (no record) or one the user has since edited or deleted
/// (record mismatch / entry gone) is left completely alone — never overwritten
/// by the mirror, never deleted on un-mirror, never re-added after a manual
/// delete. That *is* the opt-out: editing or removing the entry makes it "not
/// ours", so it stops being managed.
///
/// It **un-mirrors**: when the source `jira` disappears from the Claude config,
/// a mirror Crow wrote is dropped so a stale (possibly credential-bearing)
/// server never lingers. Both `opencode.json` and the sidecar are written `0600`
/// — the mirrored `environment`/`headers` carry the same secrets `~/.claude.json`
/// (itself `0600`) does. (A digest-only sidecar would avoid the third on-disk
/// copy, but swift-crypto's BoringSSL interop breaks the Linux CI link; all
/// three files are `0600`, so this is a duplicated-secret note, not a leak.)
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
        /// A `mcp.jira` exists that Crow did not write (user-authored, or one the
        /// user has since edited); left untouched — not overwritten, not deleted.
        case skippedUserOwned
        /// No `jira` MCP server in the Claude config to mirror, and nothing
        /// stale to remove; nothing written.
        case noSource
        /// A target/source file exists but isn't a JSON object; refused to touch it.
        case skippedUnparseable
        /// Read or write failed.
        case failed(String)
    }

    /// Mirror the user's Claude `jira` MCP into `<configHome>/opencode.json`.
    /// Pass `claudeJSONPath` / `mirrorRecordPath` to redirect the source and the
    /// provenance sidecar (tests); `nil` uses the real `~/.claude.json` and
    /// `~/.local/share/crow/opencode-mcp-mirror.json`.
    @discardableResult
    public static func installGlobalMCPConfig(
        configHome: String,
        claudeJSONPath: String? = nil,
        mirrorRecordPath: String? = nil
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
        var root: [String: Any] = ["$schema": "https://opencode.ai/config.json"]
        if fm.fileExists(atPath: targetPath) {
            guard let data = fm.contents(atPath: targetPath),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                CrowLog.info("[OpenCodeMCPConfigWriter] \(targetPath) exists but is not a JSON object; refusing to modify it")
                return .skippedUnparseable
            }
            root = parsed
        }
        var mcp = root["mcp"] as? [String: Any] ?? [:]
        let existing = mcp[serverName] as? [String: Any]

        // 3. Provenance: is the on-disk entry the exact one Crow last wrote?
        //    The record stores the entry itself (in Crow's own `0600` state dir);
        //    it can't be a hash without a crypto dependency that breaks the Linux
        //    CI link (swift-crypto's BoringSSL interop), and all three files are
        //    `0600`, so this is a duplicated-secret note, not a leak.
        let recordPath = mirrorRecordPath ?? Self.defaultMirrorRecordPath()
        var record = readMirrorRecord(path: recordPath)
        let recorded = record[serverName] as? [String: Any]
        let entryIsOurs = existing != nil && recorded != nil && jsonEqual(existing!, recorded!)

        // 4a. Source absent → un-mirror, but only an entry we actually wrote.
        if sourceServer == nil {
            guard existing != nil else {
                // Entry already gone. Keep any record: it's the durable opt-out
                // marker the register path (4c) honors, and it must survive the
                // Claude source disappearing and later returning — otherwise a
                // source round-trip would silently un-do the user's delete.
                // Nothing on disk to remove.
                return .noSource
            }
            guard entryIsOurs else {
                CrowLog.info("[OpenCodeMCPConfigWriter] mcp.\(serverName) not written by Crow; leaving it alone")
                return .skippedUserOwned
            }
            mcp.removeValue(forKey: serverName)
            if mcp.isEmpty {
                root.removeValue(forKey: "mcp")
            } else {
                root["mcp"] = mcp
            }
            if let failure = write(root, to: targetPath, configHome: configHome, fm: fm) {
                return failure
            }
            record.removeValue(forKey: serverName)
            writeMirrorRecord(record, path: recordPath, fm: fm)
            return .removed
        }

        // 4b. Source present but untranslatable (e.g. a half-edited entry) →
        //     leave the mirror alone rather than deleting it.
        guard let translated = translateClaudeServer(sourceServer!) else {
            CrowLog.info("[OpenCodeMCPConfigWriter] Claude mcpServers.\(serverName) present but not translatable; leaving OpenCode config unchanged")
            return .noSource
        }

        // 4c. Durable opt-out: the user deleted a mirror Crow wrote (entry gone,
        //     record still present). Treat the deletion as intent and don't
        //     re-add it — deleting behaves the same as editing.
        if existing == nil, recorded != nil {
            CrowLog.info("[OpenCodeMCPConfigWriter] mcp.\(serverName) removed after Crow wrote it; honoring the opt-out")
            return .skippedUserOwned
        }

        // 4d. Never clobber a user-authored entry (or the user's edits to ours).
        if existing != nil, !entryIsOurs {
            // Distinguish "we have no record for it" (user-authored, or our
            // sidecar was lost) from "the record disagrees" (user edited ours) —
            // otherwise a debugging user chasing a stale token is pointed at the
            // wrong file.
            let why = recorded == nil
                ? "no Crow record for it (user-authored, or the mirror sidecar was lost)"
                : "it differs from Crow's record (user-edited)"
            CrowLog.info("[OpenCodeMCPConfigWriter] mcp.\(serverName) left as-is — \(why); not overwriting")
            return .skippedUserOwned
        }

        // 4e. Register/update. Reaching here means either no existing entry (and
        //     no record — 4c caught deleted-with-record) or an entry that is
        //     exactly ours (so `recorded == existing`); either way it's safe to
        //     (re)write, and when it already equals the desired entry the record
        //     is already in sync — so there's nothing to re-sync.
        if let existing, jsonEqual(existing, translated) {
            return .unchanged
        }
        mcp[serverName] = translated
        root["mcp"] = mcp
        if let failure = write(root, to: targetPath, configHome: configHome, fm: fm) {
            return failure
        }
        record[serverName] = translated
        writeMirrorRecord(record, path: recordPath, fm: fm)
        return .registered
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
            CrowLog.info("[OpenCodeMCPConfigWriter] Failed to write \(path): \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Provenance record

    /// `~/.local/share/crow/opencode-mcp-mirror.json` — Crow's own state dir
    /// (alongside `crow.sock`), never the user's config. Holds the exact entry
    /// Crow last wrote per server name, so the register/remove paths can tell
    /// "ours" from "user-authored".
    static func defaultMirrorRecordPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow/opencode-mcp-mirror.json").path
    }

    /// Read the provenance sidecar. Missing or unparseable → empty (fail open:
    /// with no record every entry reads as "not ours", so we never delete or
    /// overwrite — the safe direction).
    static func readMirrorRecord(path: String) -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return root
    }

    /// Persist the provenance sidecar `0600` (it holds the same
    /// `environment`/`headers` the mirror does, in Crow's own state dir). Best
    /// effort — a failure only means the next run re-evaluates provenance and,
    /// lacking a record, treats the entry as user-owned (safe: leaves it alone).
    static func writeMirrorRecord(_ record: [String: Any], path: String, fm: FileManager) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            CrowLog.info("[OpenCodeMCPConfigWriter] Failed to write mirror record \(path): \(error.localizedDescription)")
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
            CrowLog.info("[OpenCodeMCPConfigWriter] \(claudeJSONPath) exists but is not a JSON object; ignoring")
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

    /// Structural equality via canonical JSON bytes. `NSDictionary.isEqual`
    /// can't be used here: on swift-corelibs-foundation (Linux CI) it does not
    /// deep-equate a Swift `[String]` against a JSON-decoded `NSArray`, nor a
    /// `Bool` against an `NSNumber`, so a freshly-built server never compared
    /// equal to the same server round-tripped through `opencode.json` — the
    /// idempotency check always fired and rewrote the file. Serializing both
    /// with `.sortedKeys` normalizes every value type identically on macOS and
    /// Linux, so the comparison is stable cross-platform.
    private static func jsonEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        else { return false }
        return da == db
    }
}
