import Foundation
import CrowCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Writes hook configuration that OpenAI Codex picks up. Codex reads hooks
/// from `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`) regardless
/// of which directory `codex` is invoked from — global, not per-worktree.
///
/// Because `HookConfigWriter`'s per-session API doesn't fit Codex's global
/// model, the per-session methods are intentionally no-ops. Real work happens
/// via the static `installGlobalConfig` / `installGlobalTomlConfig` calls
/// invoked once at app launch.
public struct CodexHookConfigWriter: HookConfigWriter {

    /// All hook event names Codex can dispatch (from
    /// codex-rs/hooks/schema/generated/*.input.schema.json).
    static let allEvents = [
        "SessionStart",
        "PreToolUse",
        "PostToolUse",
        "UserPromptSubmit",
        "Stop",
        "PermissionRequest",
    ]

    /// Events that should run async (fire-and-forget). Codex's hook runtime
    /// is sync-only as of v0.139.0 — declaring `async = true` causes the
    /// entry to be silently skipped on startup, which breaks Crow's
    /// session-state detection. Keep this empty until/unless Codex grows
    /// real async support upstream. Note (#903): since `crow hook-event` is
    /// fire-and-forget, even fully-sync registration no longer guarantees the
    /// daemon *applies* events in arrival order — see the "Hook async delivery"
    /// apply-order caveat in docs/agent-harness-matrix.md.
    private static let asyncEvents: Set<String> = []

    public init() {}

    // MARK: - HookConfigWriter Conformance (no-ops)

    /// No-op. Codex hooks are global, not per-worktree — see
    /// `installGlobalConfig`.
    public func writeHookConfig(worktreePath: String, sessionID: UUID, crowPath: String) throws {}

    /// No-op. Codex's global `hooks.json` stays in place when individual
    /// sessions are deleted; it serves all sessions.
    public func removeHookConfig(worktreePath: String) {}

    // MARK: - Global Configuration

    /// Build the hooks dict in the schema Codex expects. Each event invokes
    /// `<crow> hook-event --agent codex --event <Name>` with no `--session`
    /// flag — the crow server resolves the session from `cwd` in the payload.
    static func generateHooks(crowPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in allEvents {
            let command = "\(crowPath) hook-event --agent codex --event \(event)"
            var entry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5,
            ]
            if asyncEvents.contains(event) {
                entry["async"] = true
            }
            hooks[event] = [
                ["hooks": [entry]] as [String: Any]
            ]
        }
        return hooks
    }

    /// Install or refresh `<codexHome>/hooks.json` with Crow's 6 hook
    /// commands. Idempotent — re-running just rewrites the same content.
    /// Preserves any user-authored entries for events Crow doesn't manage.
    public static func installGlobalConfig(codexHome: String, crowPath: String) throws {
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")

        // Read existing hooks.json if present so user-authored entries for
        // events outside `allEvents` survive.
        var existing: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: hooksPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = parsed
        }
        var existingHooks = existing["hooks"] as? [String: Any] ?? [:]
        let ours = generateHooks(crowPath: crowPath)
        for (eventName, config) in ours {
            existingHooks[eventName] = config
        }
        existing["hooks"] = existingHooks

        let data = try JSONSerialization.data(
            withJSONObject: existing,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: hooksPath))
    }

    /// Install or update `<codexHome>/config.toml` with the
    /// `features.hooks = true` flag and the Crow `notify` line.
    /// Preserves any other user-authored config — minimal line-oriented merge
    /// avoids pulling in a TOML dependency for two simple keys.
    ///
    /// Also runs a one-shot migration: legacy installs (Crow before this
    /// fix, or older Codex versions) wrote `codex_hooks = true` under
    /// `[features]`. Codex v0.139.0+ renamed the key to `hooks` and emits
    /// a deprecation warning for the old one — strip it so users converging
    /// from older configs end up with a single, current entry.
    public static func installGlobalTomlConfig(codexHome: String, crowPath: String) throws {
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        let tomlPath = (codexHome as NSString).appendingPathComponent("config.toml")

        var content: String = ""
        if let data = FileManager.default.contents(atPath: tomlPath) {
            // "Exists but not UTF-8" must not read as "" — that would truncate a
            // config.toml holding credentials/providers on the read-modify-write
            // (#843 review round 6). Refuse instead.
            guard let text = String(data: data, encoding: .utf8) else {
                throw NSError(
                    domain: "CodexHookConfigWriter", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(tomlPath) is not valid UTF-8; refusing to rewrite"])
            }
            content = text
        }

        let notifyLine = "notify = [\"\(escapeTomlString(crowPath))\", \"codex-notify\"]"
        content = upsertTomlLine(content, key: "notify", line: notifyLine)
        // Strip the deprecated `codex_hooks` key before writing the modern
        // `hooks` key so we don't leave both lines behind on migration.
        content = removeTomlSectionLine(content, section: "features", key: "codex_hooks")
        content = upsertTomlSectionLine(
            content,
            section: "features",
            key: "hooks",
            line: "hooks = true"
        )

        // Route through the owner-only writer: this is the same `config.toml`
        // that `CodexMCPWriter` later fills with mirrored MCP `env` tokens, and
        // `installGlobalTomlConfig` runs first on every boot — writing it 0600
        // here keeps the file owner-only even on the very first boot, before the
        // mirror runs (#843 review round 2).
        try writeConfigPrivately(content, toFile: tomlPath)
    }

    // MARK: - TOML Line Editing (Minimal)

    /// Replace or append a top-level (no section) `key = …` line in `content`.
    static func upsertTomlLine(_ content: String, key: String, line: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var inSection = false
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inSection = true
                continue
            }
            if !inSection, lineKey(of: raw) == key {
                lines[i] = line
                return lines.joined(separator: "\n")
            }
        }
        // Not found — append at the top (before any section header) for
        // top-level keys, or at end if no headers.
        if let firstSection = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.hasSuffix("]")
        }) {
            lines.insert(line, at: firstSection)
            // Add a separator newline if the previous line wasn't blank.
            if firstSection > 0,
               !lines[firstSection - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("", at: firstSection)
            }
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") {
                lines.append("")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Strip a TOML end-of-line `# comment` that sits outside any double-quoted
    /// string, leaving quoted `#` intact. So `[a.b] # note` → `[a.b] `.
    static func stripTomlInlineComment(_ line: String) -> String {
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

    /// Split a TOML dotted key path into segments, respecting double-quoted
    /// segments, trimming whitespace around each dot, and unwrapping the quotes.
    /// `mcp_servers . "jira"` → `["mcp_servers", "jira"]`.
    static func splitTomlDottedPath(_ s: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == "." && !inQuotes { segments.append(unwrapTomlKey(current)); current = ""; continue }
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

    /// If `line` is a TOML table header `[a.b."c"]`, return its dotted-path
    /// segments (quotes unwrapped, whitespace-around-dots trimmed, trailing
    /// `# comment` stripped); `nil` for a non-header line. So
    /// `[mcp_servers . "jira"] # x` → `["mcp_servers", "jira"]`. Comment-,
    /// whitespace-, and quote-tolerant so a present/section match can't be
    /// defeated by a legal-but-unusual spelling that would then append a
    /// duplicate table and corrupt `config.toml` (#843 review round 4).
    static func tomlHeaderSegments(_ line: String) -> [String]? {
        let bare = stripTomlInlineComment(line).trimmingCharacters(in: .whitespaces)
        guard bare.count >= 2, bare.hasPrefix("["), bare.hasSuffix("]") else { return nil }
        return splitTomlDottedPath(String(bare.dropFirst().dropLast()))
    }

    /// Replace or insert `key = …` inside `[section]`. Adds the section if
    /// missing. Header matching is comment/whitespace/quote-tolerant via
    /// `tomlHeaderSegments`, so an existing `[section] # note` is updated in
    /// place rather than duplicated.
    static func upsertTomlSectionLine(
        _ content: String,
        section: String,
        key: String,
        line: String
    ) -> String {
        var lines = content.components(separatedBy: "\n")
        var sectionStart: Int? = nil
        var sectionEnd: Int = lines.count
        let sectionHeader = "[\(section)]"
        let targetSegments = splitTomlDottedPath(section)
        for (i, raw) in lines.enumerated() {
            let segments = tomlHeaderSegments(raw)
            if sectionStart == nil, segments == targetSegments {
                sectionStart = i
                continue
            }
            if sectionStart != nil, segments != nil {
                sectionEnd = i
                break
            }
        }

        if let start = sectionStart {
            // Search for existing key inside the section.
            for i in (start + 1)..<sectionEnd {
                if lineKey(of: lines[i]) == key {
                    lines[i] = line
                    return lines.joined(separator: "\n")
                }
            }
            lines.insert(line, at: sectionEnd)
            return lines.joined(separator: "\n")
        }

        // No `[section]` header — but the section may already exist as an inline
        // table key (legacy `[projects]` with `"/p" = { … }`, or a top-level
        // `features = { … }`). Appending a `[section]` header on top of either is
        // a duplicate-key TOML error that leaves config.toml unparseable and
        // Codex unable to start (#843 review round 7). Don't merge into the
        // inline form (rare; a current Codex migrates it to header form on its
        // next trust write) — just refuse to append a conflicting header.
        if inlineTableKeyPresent(lines, section: section) {
            return content
        }

        // Section absent — append at the end.
        if !content.isEmpty && !content.hasSuffix("\n") {
            lines.append("")
        }
        if !lines.last!.isEmpty {
            lines.append("")
        }
        lines.append(sectionHeader)
        lines.append(line)
        return lines.joined(separator: "\n")
    }

    /// Whether `lines` already define `section` as an **inline** table key rather
    /// than a `[section]` header — the legacy spellings a bare `[projects]`
    /// parent with `"/path" = { … }` entries, or a top-level `features = { … }`.
    /// Used by `upsertTomlSectionLine` to avoid appending a duplicate-key header
    /// over one (#843 review round 7). `removeTomlSectionLine` doesn't need this
    /// — it never appends, so it can't corrupt.
    static func inlineTableKeyPresent(_ lines: [String], section: String) -> Bool {
        let segments = splitTomlDottedPath(section)
        guard let leaf = segments.last else { return false }
        let parent = Array(segments.dropLast())
        // For a top-level target (`features`) the inline entry lives before the
        // first header; for `projects."/p"` it lives inside `[projects]`.
        var inParent = parent.isEmpty
        for raw in lines {
            if let header = tomlHeaderSegments(raw) {
                inParent = !parent.isEmpty && header == parent
                continue
            }
            if inParent, assignmentKeyUnquoted(of: raw) == leaf { return true }
        }
        return false
    }

    /// The unquoted key of a `key = value` line (comment-stripped), or `nil`.
    /// Splits on the first `=` so `"/p" = { trust_level = … }` yields `/p`.
    private static func assignmentKeyUnquoted(of line: String) -> String? {
        let bare = stripTomlInlineComment(line)
        guard let eq = bare.firstIndex(of: "=") else { return nil }
        let raw = String(bare[bare.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : unwrapTomlKey(raw)
    }

    /// Remove `key = …` from inside `[section]` if present. Returns the
    /// content unchanged when the section or key is absent — idempotent and
    /// safe to chain before an `upsertTomlSectionLine` call.
    static func removeTomlSectionLine(
        _ content: String,
        section: String,
        key: String
    ) -> String {
        var lines = content.components(separatedBy: "\n")
        var sectionStart: Int? = nil
        var sectionEnd: Int = lines.count
        let targetSegments = splitTomlDottedPath(section)
        for (i, raw) in lines.enumerated() {
            let segments = tomlHeaderSegments(raw)
            if sectionStart == nil, segments == targetSegments {
                sectionStart = i
                continue
            }
            if sectionStart != nil, segments != nil {
                sectionEnd = i
                break
            }
        }

        guard let start = sectionStart else { return content }
        for i in (start + 1)..<sectionEnd {
            if lineKey(of: lines[i]) == key {
                lines.remove(at: i)
                return lines.joined(separator: "\n")
            }
        }
        return content
    }

    /// Extract the bare `key` from a `key = value` TOML line, ignoring
    /// comments and quoted keys. Returns `nil` for non-assignment lines.
    private static func lineKey(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : String(key)
    }

    /// Escape a string for safe inclusion in a TOML **basic** (double-quoted)
    /// string. TOML forbids raw control characters (including newlines) inside a
    /// basic string, so a value carrying a `\n` — e.g. a PEM key or a
    /// pretty-printed JSON blob mirrored from an MCP `env` — would otherwise
    /// terminate the string early and leave `config.toml` unparseable (#830
    /// review). Escapes `\`, `"`, the named short escapes, and every other
    /// control character as `\uXXXX`.
    static func escapeTomlString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Write `content` to `path` so the file — and its transient temp — is never
    /// world-readable. `config.toml` can carry provider credentials, and a plain
    /// `write(toFile:atomically:true)` stages a temp at the process umask (often
    /// 0644) for the write+rename window, briefly exposing secrets (#830
    /// review). This stages a sibling temp created at 0600, writes into it, then
    /// `rename(2)`s it over the destination — one atomic step on the same
    /// filesystem (the temp is a sibling), so there's no window where the file is
    /// missing or world-readable. `rename(2)` is used directly rather than
    /// `FileManager.replaceItemAt`, which is unreliable on
    /// swift-corelibs-foundation (it left the destination missing on Linux CI).
    static func writeConfigPrivately(_ content: String, toFile path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = (dir as NSString).appendingPathComponent(".crow-codex-\(UUID().uuidString).tmp")
        guard fm.createFile(
            atPath: tmp,
            contents: Data(content.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Atomic replace; the 0600 temp's inode (and perms) become the target.
        let renamed = tmp.withCString { tmpC in
            path.withCString { pathC in rename(tmpC, pathC) == 0 }
        }
        guard renamed else {
            try? fm.removeItem(atPath: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
