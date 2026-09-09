import CrowCore
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Mirrors the user's Claude `jira` MCP server into Grok Build's native
/// config (`<$GROK_HOME or ~/.grok>/config.toml` `[mcp_servers.jira]`) so a
/// Grok session gets the same `jira_*` tools Claude/Cursor/OpenCode do
/// (CROW-1205 — Phase B leftover from #859).
///
/// **Where the spec comes from.** Post-CROW-528 Crow does *not* provision a
/// Jira MCP itself; Claude sessions inherit a user-provisioned `jira` server
/// from `~/.claude.json`. So "parity with Claude" means: copy *that* server
/// into Grok. No `jira` in Claude's config → no-op. Grok *can* compat-scan
/// `~/.claude.json` itself; that path is not Crow-owned (a Grok-primary box
/// with `[compat.claude] mcps = false`, or no Claude config, still has no
/// native server), and the launcher used to instruct `acli` even when compat
/// would have loaded MCP. This writer is the Crow-owned native table.
///
/// **When it runs.** Launch-gated, not daemon boot — same reason as Cursor
/// (#829): do not copy the token onto a box that merely has a `grok` binary
/// on PATH. Callers dispatch off the main actor (possibly-large
/// `~/.claude.json`).
///
/// **Merge-preserving.** `config.toml` is Grok's own user file (`[models]`,
/// credentials, other `[mcp_servers.*]`). A user-authored `jira` entry is
/// never overwritten. Crow keeps a sidecar recording the exact TOML block it
/// last wrote (`~/.local/share/crow/grok-mcp-mirror.json`, `0600`) and only
/// refreshes or un-mirrors when the on-disk table still matches that record.
/// Editing or deleting the table makes it "not ours".
///
/// **Un-mirror.** When `~/.claude.json` parses cleanly with no `jira`, a
/// table Crow wrote is dropped so a stale credential-bearing server never
/// lingers. A missing/unreadable source is left alone (a torn read must not
/// reap). Both the TOML and the sidecar are written `0600` via POSIX
/// `rename(2)` so Linux is safe and the token is never group/other-readable.
public enum GrokMCPConfigWriter {

    /// Matches Claude's `jira` key so the `jira_*` tool names the prompts
    /// reference resolve identically across harnesses.
    static let serverName = "jira"

    public enum Outcome: Equatable {
        /// `[mcp_servers.jira]` was written/updated in `config.toml`.
        case registered
        /// The source `jira` is gone and the previously-mirrored table was dropped.
        case removed
        /// The on-disk table already matched the source; nothing written.
        case unchanged
        /// A `jira` table exists that Crow did not write (user-authored, or one
        /// the user has since edited/deleted); left untouched.
        case skippedUserOwned
        /// No `jira` MCP in the Claude config to mirror, and nothing stale to remove.
        case noSource
        /// A target/source file exists but isn't usable; refused to touch it.
        case skippedUnparseable
        /// Read or write failed.
        case failed(String)
    }

    /// Mirror into Grok's default home (`GrokHome.path()` → `config.toml`).
    /// Convenience for launch sites that don't override paths.
    public static func bridgeJiraMCPDefault() {
        _ = installMCPConfig(grokHome: GrokHome.path())
    }

    /// Serializes the read-modify-write of the one global `config.toml`
    /// against concurrent bridges from parallel launches.
    private static let writeLock = NSLock()

    /// Mirror the user's Claude `jira` MCP into `<grokHome>/config.toml`.
    /// Pass `claudeJSONPath` / `mirrorRecordPath` to redirect the source and
    /// the provenance sidecar (tests); `nil` uses `~/.claude.json` and
    /// `~/.local/share/crow/grok-mcp-mirror.json`.
    @discardableResult
    public static func installMCPConfig(
        grokHome: String,
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
                CrowLog.info("[GrokMCPConfigWriter] Promoting project-scoped `jira` MCP from \(key) into global Grok config.toml")
            }
            sourceServer = entry
        case .absent:
            sourceServer = nil
        case .sourceUnavailable:
            CrowLog.info("[GrokMCPConfigWriter] \(claudePath) missing/unreadable; leaving Grok config.toml untouched")
            return .noSource
        case .unparseable:
            CrowLog.info("[GrokMCPConfigWriter] \(claudePath) exists but is not a JSON object; ignoring")
            return .skippedUnparseable
        }

        let tomlPath = (grokHome as NSString).appendingPathComponent("config.toml")
        let fm = FileManager.default
        var content = ""
        if let data = fm.contents(atPath: tomlPath) {
            guard let text = String(data: data, encoding: .utf8) else {
                CrowLog.info("[GrokMCPConfigWriter] \(tomlPath) is not valid UTF-8; refusing to rewrite")
                return .skippedUnparseable
            }
            content = text
        }

        let present = serverAlreadyPresent(content, name: serverName)
        let extracted = extractServerBlock(content, name: serverName)
        let recordPath = mirrorRecordPath ?? defaultMirrorRecordPath()
        var record = readMirrorRecord(path: recordPath)
        let recorded = record[serverName] as? String
        let entryIsOurs = present && recorded != nil && extracted == recorded

        // Source absent → un-mirror, but only a table we actually wrote.
        if sourceServer == nil {
            guard present else { return .noSource }
            guard entryIsOurs else {
                CrowLog.info("[GrokMCPConfigWriter] mcp_servers.\(serverName) not written by Crow; leaving it alone")
                return .skippedUserOwned
            }
            let next = withoutServer(content, name: serverName)
            if let failure = writeToml(next, to: tomlPath, grokHome: grokHome, fm: fm) {
                return failure
            }
            record.removeValue(forKey: serverName)
            writeMirrorRecord(record, path: recordPath, fm: fm)
            return .removed
        }

        guard let translated = translateClaudeServer(name: serverName, def: sourceServer!) else {
            CrowLog.info("[GrokMCPConfigWriter] Claude mcpServers.\(serverName) present but not translatable; leaving Grok config unchanged")
            return .noSource
        }
        let desiredBlock = serverBlock(translated)

        // Durable opt-out: the user deleted a table Crow wrote (entry gone,
        // record still present). Don't re-add it.
        if !present, recorded != nil {
            CrowLog.info("[GrokMCPConfigWriter] mcp_servers.\(serverName) removed after Crow wrote it; honoring the opt-out")
            return .skippedUserOwned
        }

        // Never clobber a user-authored entry (or the user's edits to ours).
        if present, !entryIsOurs {
            let why = recorded == nil
                ? "no Crow record for it (user-authored, or the mirror sidecar was lost)"
                : "it differs from Crow's record (user-edited)"
            CrowLog.info("[GrokMCPConfigWriter] mcp_servers.\(serverName) left as-is — \(why); not overwriting")
            return .skippedUserOwned
        }

        if present, extracted == desiredBlock {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tomlPath)
            return .unchanged
        }

        var next = present ? withoutServer(content, name: serverName) : content
        next = appendServerBlock(next, block: desiredBlock)
        if let failure = writeToml(next, to: tomlPath, grokHome: grokHome, fm: fm) {
            return failure
        }
        record[serverName] = desiredBlock
        writeMirrorRecord(record, path: recordPath, fm: fm)
        return .registered
    }

    /// Whether `~/.claude.json` (or `claudeJSONPath`) declares a `jira` MCP
    /// server Crow can mirror. Used by `GrokLauncher` so the seed prompt names
    /// `jira_*` only when a bridge is expected; a Grok-primary host with no
    /// Claude Jira MCP keeps the `acli` arm.
    public static func claudeHasJiraServer(claudeJSONPath: String? = nil) -> Bool {
        if case .found(let entry, origin: _) = ClaudeMCPSource.lookupJira(from: claudeJSONPath) {
            return translateClaudeServer(name: serverName, def: entry) != nil
        }
        return false
    }

    // MARK: - Translation

    /// A translated MCP server ready to serialize as a Grok `[mcp_servers.*]`
    /// table. Either `command` (stdio) or `url` (HTTP/SSE) is set.
    struct Server {
        var name: String
        var command: String?
        var args: [String]
        var env: [(String, String)]
        var url: String?
        var headers: [(String, String)]
    }

    /// Translate one Claude `mcpServers.<name>` definition into a Grok table.
    /// Returns `nil` when the definition has neither `command` nor `url`.
    /// Grok's `url` form is HTTP/SSE and *does* accept `headers` (unlike Codex),
    /// so a remote Claude server carrying `Authorization` is mirrored faithfully.
    static func translateClaudeServer(name: String, def: [String: Any]) -> Server? {
        let command = (def["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let url = (def["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let args = (def["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        let env = stringifyMap(def["env"] as? [String: Any])
        let headers = stringifyMap(def["headers"] as? [String: Any])

        if command != nil {
            return Server(name: name, command: command, args: args, env: env, url: nil, headers: [])
        }
        if url != nil {
            return Server(name: name, command: nil, args: [], env: env, url: url, headers: headers)
        }
        return nil
    }

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
            if !server.headers.isEmpty {
                let pairs = server.headers
                    .map { "\(keyToken($0.0)) = \"\(escape($0.1))\"" }
                    .joined(separator: ", ")
                lines.append("headers = { \(pairs) }")
            }
        }
        if !server.env.isEmpty {
            let pairs = server.env
                .map { "\(keyToken($0.0)) = \"\(escape($0.1))\"" }
                .joined(separator: ", ")
            lines.append("env = { \(pairs) }")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func appendServerBlock(_ content: String, block: String) -> String {
        var out = content
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        out += block
        return out
    }

    /// Whether `content` already declares an MCP server named `name`, so we
    /// never append a duplicate (TOML rejects a redefined table). Recognizes
    /// the dotted header, a sub-table, and an inline key inside `[mcp_servers]`.
    static func serverAlreadyPresent(_ content: String, name: String) -> Bool {
        var inParentTable = false
        for raw in content.components(separatedBy: "\n") {
            if let segments = tomlHeaderSegments(raw) {
                if isJiraServerPath(segments, name: name) { return true }
                inParentTable = (segments == ["mcp_servers"])
                continue
            }
            if inParentTable {
                let bare = stripTomlInlineComment(raw).trimmingCharacters(in: .whitespaces)
                if bare.isEmpty { continue }
                if assignmentKey(of: bare) == name { return true }
            }
        }
        return false
    }

    /// The exact TOML block for `[mcp_servers.<name>]` (and any sub-tables),
    /// or `nil` when only an inline `[mcp_servers] name = { … }` form exists.
    /// Used to compare against the sidecar record.
    static func extractServerBlock(_ content: String, name: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        var collected: [String] = []
        var collecting = false
        for raw in lines {
            if let segments = tomlHeaderSegments(raw) {
                if isJiraServerPath(segments, name: name) {
                    collecting = true
                    collected.append(raw)
                    continue
                }
                if collecting { break }
                continue
            }
            if collecting { collected.append(raw) }
        }
        guard !collected.isEmpty else { return nil }
        while let last = collected.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            collected.removeLast()
        }
        return collected.joined(separator: "\n") + "\n"
    }

    /// Drop `[mcp_servers.<name>]` and any sub-tables, plus an inline
    /// `name = { … }` inside a bare `[mcp_servers]` parent. Other tables stay.
    static func withoutServer(_ content: String, name: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var out: [String] = []
        var skipping = false
        var inParentTable = false
        for raw in lines {
            if let segments = tomlHeaderSegments(raw) {
                skipping = isJiraServerPath(segments, name: name)
                inParentTable = (segments == ["mcp_servers"])
                if skipping { continue }
                out.append(raw)
                continue
            }
            if skipping { continue }
            if inParentTable, assignmentKey(of: stripTomlInlineComment(raw).trimmingCharacters(in: .whitespaces)) == name {
                continue
            }
            out.append(raw)
        }
        // Collapse a trailing run of blank lines to a single newline.
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            out.removeLast()
        }
        if out.isEmpty { return "" }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Provenance record

    static func defaultMirrorRecordPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow/grok-mcp-mirror.json").path
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
            CrowLog.info("[GrokMCPConfigWriter] Failed to write mirror record \(path): \(error.localizedDescription)")
        }
    }

    // MARK: - Atomic owner-only write

    private static func writeToml(
        _ content: String,
        to path: String,
        grokHome: String,
        fm: FileManager
    ) -> Outcome? {
        do {
            try fm.createDirectory(atPath: grokHome, withIntermediateDirectories: true)
            guard writePrivately(Data(content.utf8), to: path) else {
                return .failed("atomic write to \(path) failed")
            }
            return nil
        } catch {
            CrowLog.info("[GrokMCPConfigWriter] Failed to write \(path): \(error.localizedDescription)")
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
        let tmp = (dir as NSString).appendingPathComponent(".crow-grok-mcp-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o600]) else {
            CrowLog.info("[GrokMCPConfigWriter] Failed to create temp for \(path)")
            return false
        }
        let renamed = tmp.withCString { tmpC in
            path.withCString { pathC in rename(tmpC, pathC) == 0 }
        }
        if !renamed {
            CrowLog.info("[GrokMCPConfigWriter] atomic rename to \(path) failed (errno \(errno))")
            try? fm.removeItem(atPath: tmp)
            return false
        }
        return true
    }

    // MARK: - TOML helpers

    private static func isJiraServerPath(_ segments: [String], name: String) -> Bool {
        segments.count >= 2 && segments[0] == "mcp_servers" && segments[1] == name
    }

    static func tomlHeaderSegments(_ line: String) -> [String]? {
        let bare = stripTomlInlineComment(line).trimmingCharacters(in: .whitespaces)
        guard bare.count >= 2, bare.hasPrefix("["), bare.hasSuffix("]") else { return nil }
        return splitTomlDottedPath(String(bare.dropFirst().dropLast()))
    }

    private static func splitTomlDottedPath(_ s: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == "." && !inQuotes {
                segments.append(unwrapTomlKey(current))
                current = ""
                continue
            }
            current.append(ch)
        }
        segments.append(unwrapTomlKey(current))
        return segments
    }

    private static func unwrapTomlKey(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    private static func stripTomlInlineComment(_ line: String) -> String {
        var inQuotes = false
        var escaped = false
        var out = ""
        for ch in line {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); out.append(ch); continue }
            if ch == "#" && !inQuotes { break }
            out.append(ch)
        }
        return out
    }

    private static func assignmentKey(of line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let raw = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return unwrapTomlKey(raw)
    }

    static func keyToken(_ key: String) -> String {
        let bare = !key.isEmpty && key.allSatisfy { c in
            (c >= "A" && c <= "Z") || (c >= "a" && c <= "z")
                || (c >= "0" && c <= "9") || c == "_" || c == "-"
        }
        return bare ? key : "\"\(escape(key))\""
    }

    private static func escape(_ s: String) -> String {
        GrokTrustSeeder.escapeTomlString(s)
    }

    private static func stringifyMap(_ dict: [String: Any]?) -> [(String, String)] {
        guard let dict else { return [] }
        var out: [(String, String)] = []
        for key in dict.keys.sorted() {
            if let value = stringify(dict[key]) { out.append((key, value)) }
        }
        return out
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
