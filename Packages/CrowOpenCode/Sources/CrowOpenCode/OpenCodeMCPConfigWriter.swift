import Crypto
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
/// already lands. So Crow keeps a sidecar recording the SHA-256 digest of the
/// entry it last wrote (`~/.local/share/crow/opencode-mcp-mirror.json`, `0600`)
/// and only ever touches `mcp.jira` when the on-disk entry still hashes to that
/// digest. A user-authored `jira` (no record) or one the user has since edited
/// or deleted (digest mismatch / entry gone) is left completely alone — never
/// overwritten by the mirror, never deleted on un-mirror, never re-added after a
/// manual delete. That *is* the opt-out: editing or removing the entry makes it
/// "not ours", so it stops being managed.
///
/// It **un-mirrors**: when the source `jira` disappears from the Claude config,
/// a mirror Crow wrote is dropped so a stale (possibly credential-bearing)
/// server never lingers. The `opencode.json` file is written `0600` — the
/// mirrored `environment`/`headers` carry the same secrets `~/.claude.json`
/// (itself `0600`) does. The sidecar stores only digests (no token) and is
/// `0600` too.
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
                NSLog("[OpenCodeMCPConfigWriter] %@ exists but is not a JSON object; refusing to modify it", targetPath)
                return .skippedUnparseable
            }
            root = parsed
        }
        var mcp = root["mcp"] as? [String: Any] ?? [:]
        let existing = mcp[serverName] as? [String: Any]

        // 3. Provenance: does the on-disk entry hash to the digest Crow last
        //    wrote? The record stores only a SHA-256 of the canonical entry, not
        //    the entry itself — so the token isn't copied to a third file.
        let recordPath = mirrorRecordPath ?? Self.defaultMirrorRecordPath()
        var record = readMirrorRecord(path: recordPath)
        let recordedDigest = record[serverName] as? String
        let existingDigest = existing.flatMap(canonicalDigest)
        let entryIsOurs = existing != nil && recordedDigest != nil && existingDigest == recordedDigest

        // 4a. Source absent → un-mirror, but only an entry we actually wrote.
        if sourceServer == nil {
            guard existing != nil else {
                // Nothing in config; drop any now-stale record.
                if record[serverName] != nil {
                    record.removeValue(forKey: serverName)
                    writeMirrorRecord(record, path: recordPath, fm: fm)
                }
                return .noSource
            }
            guard entryIsOurs else {
                NSLog("[OpenCodeMCPConfigWriter] mcp.%@ not written by Crow; leaving it alone", serverName)
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
            NSLog("[OpenCodeMCPConfigWriter] Claude mcpServers.%@ present but not translatable; leaving OpenCode config unchanged", serverName)
            return .noSource
        }

        // 4c. Durable opt-out: the user deleted a mirror Crow wrote (entry gone,
        //     record still present). Treat the deletion as intent and don't
        //     re-add it — deleting behaves the same as editing.
        if existing == nil, recordedDigest != nil {
            NSLog("[OpenCodeMCPConfigWriter] mcp.%@ removed after Crow wrote it; honoring the opt-out", serverName)
            return .skippedUserOwned
        }

        // 4d. Never clobber a user-authored entry (or the user's edits to ours).
        if existing != nil, !entryIsOurs {
            NSLog("[OpenCodeMCPConfigWriter] mcp.%@ not written by Crow; not overwriting", serverName)
            return .skippedUserOwned
        }

        // 4e. Register/update. Reaching here means either no existing entry (and
        //     no record — 4c caught deleted-with-record) or an entry that is
        //     exactly ours; either way it's safe to (re)write.
        let desiredDigest = canonicalDigest(translated)
        if let existingDigest, existingDigest == desiredDigest {
            return .unchanged
        }
        mcp[serverName] = translated
        root["mcp"] = mcp
        if let failure = write(root, to: targetPath, configHome: configHome, fm: fm) {
            return failure
        }
        if let desiredDigest {
            record[serverName] = desiredDigest
            writeMirrorRecord(record, path: recordPath, fm: fm)
        }
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
            NSLog("[OpenCodeMCPConfigWriter] Failed to write %@: %@", path, error.localizedDescription)
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Provenance record

    /// `~/.local/share/crow/opencode-mcp-mirror.json` — Crow's own state dir
    /// (alongside `crow.sock`), never the user's config. Maps each server name
    /// to the SHA-256 digest of the entry Crow last wrote, so the register/remove
    /// paths can tell "ours" from "user-authored" without storing the entry (and
    /// its token) a third time.
    static func defaultMirrorRecordPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow/opencode-mcp-mirror.json").path
    }

    /// Read the provenance sidecar (`{ "<server>": "<sha256-hex>" }`). Missing or
    /// unparseable → empty (fail open: with no record every entry reads as "not
    /// ours", so we never delete or overwrite — the safe direction).
    static func readMirrorRecord(path: String) -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return root
    }

    /// Persist the provenance sidecar `0600`. It holds only digests now (no
    /// secret), but `0600` still keeps the "which servers does Crow manage" list
    /// owner-only. Best effort — a failure only means the next run re-evaluates
    /// provenance and, lacking a record, treats the entry as user-owned (safe:
    /// leaves it alone).
    static func writeMirrorRecord(_ record: [String: Any], path: String, fm: FileManager) {
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            NSLog("[OpenCodeMCPConfigWriter] Failed to write mirror record %@: %@", path, error.localizedDescription)
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

    /// SHA-256 hex digest of an entry's canonical JSON, used as the provenance
    /// fingerprint. `.sortedKeys` normalizes every value type identically on
    /// macOS and Linux (a freshly-built `[String]`/`Bool` and the same value
    /// round-tripped through JSON as `NSArray`/`NSNumber` serialize to identical
    /// bytes) — the reason `NSDictionary.isEqual`, which does *not* deep-equate
    /// those across swift-corelibs-foundation, can't be used. Storing the digest
    /// rather than the entry keeps the Jira token out of the sidecar entirely.
    static func canonicalDigest(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
