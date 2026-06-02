import Foundation
import CrowCore

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

    /// Post-execution events safe to run async (fire-and-forget).
    private static let asyncEvents: Set<String> = ["PostToolUse", "Stop"]

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
    /// `features.codex_hooks = true` flag and the Crow `notify` line.
    /// Preserves any other user-authored config — minimal line-oriented merge
    /// avoids pulling in a TOML dependency for two simple keys.
    public static func installGlobalTomlConfig(codexHome: String, crowPath: String) throws {
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        let tomlPath = (codexHome as NSString).appendingPathComponent("config.toml")

        var content: String = ""
        if let data = FileManager.default.contents(atPath: tomlPath),
           let text = String(data: data, encoding: .utf8) {
            content = text
        }

        let notifyLine = "notify = [\"\(escapeTomlString(crowPath))\", \"codex-notify\"]"
        content = upsertTomlLine(content, key: "notify", line: notifyLine)
        content = upsertTomlSectionLine(
            content,
            section: "features",
            key: "codex_hooks",
            line: "codex_hooks = true"
        )

        try content.write(toFile: tomlPath, atomically: true, encoding: .utf8)
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

    /// Replace or insert `key = …` inside `[section]`. Adds the section if
    /// missing.
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
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == sectionHeader {
                sectionStart = i
                continue
            }
            if let _ = sectionStart, trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
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

    /// Extract the bare `key` from a `key = value` TOML line, ignoring
    /// comments and quoted keys. Returns `nil` for non-assignment lines.
    private static func lineKey(of raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[trimmed.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : String(key)
    }

    /// Escape backslash and double-quote for safe inclusion in a TOML
    /// double-quoted string.
    static func escapeTomlString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
