import Foundation
import CrowCore
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Writes OpenAI Codex's **per-worktree** hook configuration into a worktree's
/// `.codex/hooks.json`, with the Crow session UUID baked into every command
/// (`hook-event --session <uuid>`). Mirrors `ClaudeHookConfigWriter` /
/// `CursorHookConfigWriter` / `MuseHookConfigWriter` — one config per session
/// directory — closing the shared-`cwd` collision the old global config had
/// (CROW-1060, closing the #830 deferral).
///
/// **Why per-worktree, not global.** Codex loads project-scoped hooks from
/// `<project-root>/.codex/hooks.json` (in **trusted** projects only — see
/// `CodexTrustSeeder`) and layers them on top of any global
/// `$CODEX_HOME/hooks.json`, running *both*. So a leftover global config a
/// prior Crow installed plus a per-worktree config would fire each event
/// **twice** and `hook-event` would double-count. That is exactly why #830 held
/// the per-worktree cutover: the fix is to make per-worktree the sole authority
/// and strip the managed global entries once, which `removeManagedGlobalConfig`
/// does at daemon boot (mirroring `CursorHookConfigWriter`). Per-worktree also
/// routes the **Manager** session, which runs in the devRoot (not a registered
/// worktree) and so was previously unroutable by `cwd` match.
///
/// **User-owned entries are respected.** Unlike Claude's gitignored,
/// local-only `.claude/settings.local.json`, `.codex/hooks.json` is a
/// conventional project file a user may already ship. So write/remove key on a
/// Crow marker (`hook-event --session` in every command) and follow Cursor/Muse's
/// protections: a git-tracked file is left untouched (an unattended `.job`'s
/// `git add -A` must not commit Crow's absolute crow-path + dead session UUID
/// into the shared repo), an existing file that isn't Crow-owned (or is
/// unparseable) is left alone, and an untracked Crow write is git-excluded.
///
/// The `.codex/config.toml` feature flag (`[features] hooks = true`) that
/// *enables* the hook subsystem, the deprecated-key migration, and the
/// retirement of the legacy `notify` bridge line all live in
/// `installGlobalTomlConfig`, run once at boot — that file also carries Codex's
/// own model/providers/credentials and the mirrored MCP `env` (`CodexMCPWriter`)
/// and per-worktree trust (`CodexTrustSeeder`), so it is *edited*, never owned.
public struct CodexHookConfigWriter: HookConfigWriter {

    /// All hook event names Codex can dispatch (from
    /// codex-rs/hooks/schema/generated/*.input.schema.json). `CodexSignalSource`
    /// maps each onto Crow's state machine.
    static let allEvents = [
        "SessionStart",
        "PreToolUse",
        "PostToolUse",
        "UserPromptSubmit",
        "Stop",
        "PermissionRequest",
    ]

    /// Events Crow runs async (fire-and-forget) **when the installed Codex is
    /// new enough** — see `CodexVersionProbe`, which gates `asyncHooksSupported`
    /// on `codex >= 0.148.0`. On older builds the set is unused and every hook
    /// is registered sync, because an `async: true` there isn't downgraded, it
    /// is *skipped* — which would silently stop Crow's session-state detection.
    ///
    /// The membership mirrors `ClaudeHookConfigWriter.asyncEvents`, minus the
    /// events Codex doesn't emit: post-execution only. `PreToolUse` stays sync
    /// deliberately so it is *accepted* by the daemon ahead of the
    /// `PermissionRequest` that follows it (#903 apply-order caveat — the
    /// non-self-healing permission-badge inversion; see
    /// docs/agent-harness-matrix.md).
    private static let asyncEvents: Set<String> = ["PostToolUse"]

    /// Whether this writer may emit `async: true` — `CodexVersionProbe`'s
    /// verdict, taken at daemon boot and baked into the agent's writer
    /// (`CrowDaemon` re-registers Codex with the probed value). Defaults to
    /// `false` so any caller that hasn't probed gets the always-safe sync
    /// registration (CROW-999).
    public let asyncHooksSupported: Bool

    public init(asyncHooksSupported: Bool = false) {
        self.asyncHooksSupported = asyncHooksSupported
    }

    // MARK: - Hook document

    /// Build the Codex hooks document (`{ "hooks": { … } }`) for a session.
    /// Each event invokes
    /// `<crow> hook-event --session <UUID> --agent codex --event <Name>` so the
    /// server routes by UUID rather than resolving the session from `cwd`.
    static func generateDocument(
        sessionID: UUID,
        crowPath: String,
        asyncHooksSupported: Bool
    ) -> [String: Any] {
        let sid = sessionID.uuidString
        var hooks: [String: Any] = [:]
        for event in allEvents {
            // Codex runs the command through a shell, so quote the crow path —
            // `resolveCrowBinary` prefers `{devRoot}/.claude/bin/crow` and devRoot
            // is user-chosen (`/Users/x/My Projects/…` would otherwise split the
            // command and silently stop every hook from firing).
            let command = "\(ShellLaunchArgs.shellQuote(crowPath)) hook-event --session \(sid) --agent codex --event \(event)"
            var entry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5,
            ]
            if asyncHooksSupported && asyncEvents.contains(event) {
                entry["async"] = true
            }
            hooks[event] = [
                ["hooks": [entry]] as [String: Any]
            ]
        }
        return ["hooks": hooks]
    }

    // MARK: - HookConfigWriter Conformance

    /// Write `<worktreePath>/.codex/hooks.json` with the session UUID baked in.
    /// See the type doc for the skip conditions (git-tracked, not Crow-owned,
    /// unparseable).
    public func writeHookConfig(
        worktreePath: String,
        sessionID: UUID,
        crowPath: String
    ) throws {
        let codexDir = Self.codexDir(worktreePath)
        let filePath = (codexDir as NSString).appendingPathComponent(Self.fileName)
        let relativePath = ".codex/\(Self.fileName)"

        // If the repo *tracks* `.codex/hooks.json`, refuse to write into it:
        // `.git/info/exclude` has no effect on tracked files, so a `git add -A`
        // would commit Crow's crow-path + dead session UUID into the shared repo.
        // Checked unconditionally so a tracked-but-deleted file is still caught.
        if Self.isGitTracked(worktreePath: worktreePath, relativePath: relativePath) {
            CrowLog.info("[CodexHookConfigWriter] \(worktreePath)/\(relativePath) is git-tracked; not writing Crow's session hooks into a committed file. Gitignore/untrack it to enable hook-based state detection for this worktree.")
            return
        }

        // If the file exists but isn't Crow-owned (a user's own hooks) or is
        // unparseable (a torn write / hand-edit), leave it untouched rather than
        // clobber the user's config.
        if let existing = FileManager.default.contents(atPath: filePath) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
                  Self.isCrowOwned(parsed) else {
                CrowLog.info("[CodexHookConfigWriter] \(filePath) exists and is not Crow-owned (or is unparseable); leaving it untouched.")
                return
            }
        }

        try FileManager.default.createDirectory(atPath: codexDir, withIntermediateDirectories: true)

        let document = Self.generateDocument(
            sessionID: sessionID,
            crowPath: crowPath,
            asyncHooksSupported: asyncHooksSupported)
        let data = try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        // Atomic (temp + rename): a crash mid-write would otherwise leave a
        // truncated file the not-Crow-owned guard then refuses to touch, silently
        // disabling this worktree's hook-based state detection forever.
        try data.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
        Self.ensureGitExcluded(worktreePath: worktreePath, pattern: relativePath)
    }

    /// Remove Crow's `.codex/hooks.json` when it is Crow-owned. Leaves a user's
    /// own file untouched. Prunes `.codex/` when left empty.
    public func removeHookConfig(worktreePath: String) {
        let codexDir = Self.codexDir(worktreePath)
        let filePath = (codexDir as NSString).appendingPathComponent(Self.fileName)
        if let data = FileManager.default.contents(atPath: filePath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           Self.isCrowOwned(parsed) {
            try? FileManager.default.removeItem(atPath: filePath)
        }
        Self.removeIfEmpty(codexDir)
    }

    // MARK: - Crow-owned probe

    /// A per-worktree file is Crow-owned when every registered event's command
    /// contains `hook-event --session`. A user's own hooks.json will not.
    static func isCrowOwned(_ document: [String: Any]) -> Bool {
        guard let hooks = document["hooks"] as? [String: Any] else { return false }
        guard !hooks.isEmpty else { return false }
        for event in allEvents {
            guard let groups = hooks[event] as? [[String: Any]],
                  let inner = groups.first?["hooks"] as? [[String: Any]],
                  let command = inner.first?["command"] as? String,
                  command.contains("hook-event --session") else {
                return false
            }
        }
        return true
    }

    // MARK: - Global-config migration (one-time cleanup)

    /// Strip Crow's managed hook groups from the **global**
    /// `<codexHome>/hooks.json` a prior Crow installed. Per-worktree configs are
    /// now the authority (CROW-1060); because Codex layers global + project hooks
    /// and runs both, a surviving global config would double-fire every event.
    /// Only Crow's groups are removed (a command shelling
    /// `crow hook-event … --agent codex` — matches the legacy cwd-resolved form
    /// that carried no `--session`), so a user's own hooks — even for the same
    /// event name — survive. Deletes the file when nothing meaningful remains.
    /// Mirrors `CursorHookConfigWriter.removeManagedGlobalConfig`.
    public static func removeManagedGlobalConfig(codexHome: String) {
        let hooksPath = (codexHome as NSString).appendingPathComponent("hooks.json")
        guard let data = FileManager.default.contents(atPath: hooksPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        var changed = false
        for event in allEvents {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            let before = groups.count
            groups.removeAll { groupIsCrowManagedGlobal($0) }
            if groups.count == before { continue }
            changed = true
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        guard changed else { return }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        // Nothing meaningful left — remove the file rather than leave a husk.
        if root.isEmpty {
            try? FileManager.default.removeItem(atPath: hooksPath)
            return
        }
        do {
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: hooksPath), options: [.atomic])
        } catch {
            CrowLog.info("[CodexHookConfigWriter] Failed to rewrite \(hooksPath): \(error.localizedDescription)")
        }
    }

    /// Whether a global hook group (`{"hooks": [{command…}]}`) is one Crow
    /// installed via the retired global writer — its command shells
    /// `crow hook-event … --agent codex`. A user's own command for the same
    /// event won't carry both tokens.
    private static func groupIsCrowManagedGlobal(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        for entry in inner {
            guard let command = entry["command"] as? String else { continue }
            if command.contains("hook-event") && command.contains("--agent codex") {
                return true
            }
        }
        return false
    }

    /// Install or update `<codexHome>/config.toml` with the `[features] hooks =
    /// true` flag that *enables* Codex's hook subsystem (per-worktree
    /// `.codex/hooks.json` won't load without it). Preserves every other
    /// user-authored line — a minimal line-oriented merge avoids pulling in a
    /// TOML dependency for one key.
    ///
    /// Also runs two one-shot migrations:
    ///  - Legacy installs wrote `codex_hooks = true` under `[features]`; Codex
    ///    v0.139.0+ renamed the key to `hooks` and warns on the old one — strip it.
    ///  - Crow before CROW-1060 wrote a `notify = ["<crow>", "codex-notify"]`
    ///    line to bridge Codex's post-turn callback into `hook-event`. That
    ///    bridge is retired now that per-worktree hooks (which carry a `Stop`
    ///    event) are the sole signal path, and leaving it would double-count
    ///    turn completion — so strip our `notify` line while leaving a user's own.
    public static func installGlobalTomlConfig(codexHome: String) throws {
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

        // Retire the legacy `notify` bridge line Crow used to write (CROW-1060).
        content = removeCrowNotifyLine(content)
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

    /// Remove a top-level (no section) `notify = …` line whose value references
    /// Crow's `codex-notify` bridge, leaving a user's own `notify` for another
    /// tool intact. Idempotent — content unchanged when no such line exists.
    static func removeCrowNotifyLine(_ content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var inSection = false
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inSection = true
                continue
            }
            if !inSection, lineKey(of: raw) == "notify", raw.contains("codex-notify") {
                lines.remove(at: i)
                return lines.joined(separator: "\n")
            }
        }
        return content
    }

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

    // MARK: - Paths

    static let fileName = "hooks.json"

    private static func codexDir(_ worktree: String) -> String {
        (worktree as NSString).appendingPathComponent(".codex")
    }

    private static func removeIfEmpty(_ dir: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir), contents.isEmpty else { return }
        try? fm.removeItem(atPath: dir)
    }

    // MARK: - Git-tracked probe (mirrors CursorHookConfigWriter / MuseHookConfigWriter)

    private nonisolated(unsafe) static var trackedCache: [String: Bool] = [:]
    private static let trackedCacheLock = NSLock()

    private static func isGitTracked(worktreePath: String, relativePath: String) -> Bool {
        let cacheKey = worktreePath + "\u{0}" + relativePath
        trackedCacheLock.lock()
        if let cached = trackedCache[cacheKey] {
            trackedCacheLock.unlock()
            return cached
        }
        trackedCacheLock.unlock()

        let result = probeGitTracked(worktreePath: worktreePath, relativePath: relativePath)

        trackedCacheLock.lock()
        trackedCache[cacheKey] = result
        trackedCacheLock.unlock()
        return result
    }

    /// Reset the tracked-ness cache (tests only).
    static func resetTrackedCacheForTesting() {
        trackedCacheLock.lock()
        trackedCache.removeAll()
        trackedCacheLock.unlock()
    }

    private static func probeGitTracked(worktreePath: String, relativePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", worktreePath, "ls-files", "--error-unmatch", relativePath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        if done.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    // MARK: - Git exclude

    static func ensureGitExcluded(worktreePath: String, pattern: String) {
        guard let excludePath = gitInfoExcludePath(worktreePath: worktreePath) else { return }
        let existing = (try? String(contentsOfFile: excludePath, encoding: .utf8)) ?? ""
        let alreadyListed = existing
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == pattern }
        if alreadyListed { return }

        var updated = existing
        if !updated.isEmpty && !updated.hasSuffix("\n") { updated += "\n" }
        updated += pattern + "\n"
        try? FileManager.default.createDirectory(
            atPath: (excludePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? updated.write(toFile: excludePath, atomically: true, encoding: .utf8)
    }

    private static func gitInfoExcludePath(worktreePath: String) -> String? {
        let fm = FileManager.default
        let dotGit = (worktreePath as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            return (dotGit as NSString).appendingPathComponent("info/exclude")
        }
        // Linked worktree: `.git` is a file `gitdir: <path>`.
        guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }
        var gitDir = String(trimmed.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        if !(gitDir as NSString).isAbsolutePath {
            gitDir = (worktreePath as NSString).appendingPathComponent(gitDir)
        }
        gitDir = (gitDir as NSString).standardizingPath
        // The `info/exclude` in the *common* dir applies to all worktrees; use
        // it when a `commondir` pointer exists.
        let commonDirFile = (gitDir as NSString).appendingPathComponent("commondir")
        if let common = try? String(contentsOfFile: commonDirFile, encoding: .utf8) {
            var commonPath = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(commonPath as NSString).isAbsolutePath {
                commonPath = (gitDir as NSString).appendingPathComponent(commonPath)
            }
            return ((commonPath as NSString).standardizingPath as NSString)
                .appendingPathComponent("info/exclude")
        }
        return (gitDir as NSString).appendingPathComponent("info/exclude")
    }
}
