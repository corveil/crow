import Foundation
import CrowCore

/// Writes Cursor's per-worktree hook configuration into
/// `<worktree>/.cursor/hooks.json`, with the Crow session UUID baked into
/// every command (`hook-event --session <uuid>`). Mirrors
/// `ClaudeHookConfigWriter` — one config per session directory, no global
/// config — which is what closes the shared-`cwd` collision the global MVP
/// had (#829).
///
/// **Why per-project, not global:** Cursor merges hook configs from every
/// source and runs *all* matching hooks (project takes precedence only on
/// conflicting *responses*). So a leftover global `~/.cursor/hooks.json` +
/// a per-worktree config would fire each event **twice**. Per-project-only
/// (like Claude) sidesteps that, and — unlike the old global config's
/// cwd-resolution — it can actually route the **Manager** session, which
/// runs in the devRoot (not a registered worktree) and so was previously
/// unroutable. `LaunchScaffold` calls `removeManagedGlobalConfig` to migrate
/// users off any global config a prior Crow installed.
///
/// Cursor's native event names are camelCase (`preToolUse`, `stop`) but it
/// documents exit-code 0/2 semantics and the `CLAUDE_PROJECT_DIR` alias as
/// "matching Claude Code behavior for compatibility." We collapse the
/// camelCase ↔ PascalCase mapping into this writer: the JSON key uses
/// Cursor's camelCase form, and the `--event <Name>` argument inside the
/// command uses the Crow-canonical PascalCase form. That lets
/// `CursorSignalSource` share Claude/Codex's event vocabulary verbatim.
public struct CursorHookConfigWriter: HookConfigWriter {

    /// Curated event subset matching what `CursorSignalSource` handles, plus
    /// `Notification` (mapped from `afterAgentResponse` as a safety net for
    /// completion detection where `stop` may not fire). Keyed by Cursor's
    /// camelCase event name; value is the Crow-canonical PascalCase event
    /// name written into the `--event` argument.
    static let eventMapping: [(cursorKey: String, crowEvent: String)] = [
        ("sessionStart", "SessionStart"),
        ("preToolUse", "PreToolUse"),
        ("postToolUse", "PostToolUse"),
        ("beforeSubmitPrompt", "UserPromptSubmit"),
        ("stop", "Stop"),
        ("afterAgentResponse", "Notification"),
    ]

    /// Post-execution events safe to run async (fire-and-forget).
    /// `Stop` stays synchronous because the state-transition timing
    /// matters for the UI; `PostToolUse` and `Notification` are
    /// observational so async is fine.
    private static let asyncCrowEvents: Set<String> = ["PostToolUse", "Notification"]

    /// Substring that identifies a Crow-installed hook command, used by
    /// `removeManagedGlobalConfig` to strip only our entries (leaving a user's
    /// own hook for the same event name untouched).
    private static let crowCommandMarker = "hook-event --session"
    /// Legacy marker for the global (cwd-resolved, no `--session`) commands a
    /// prior Crow installed — also stripped during migration.
    private static let legacyGlobalMarker = "hook-event --agent cursor"

    public init() {}

    // MARK: - Hook generation

    /// Build the hooks dict in the schema Cursor expects, with `sessionID`
    /// baked into each command so the crow server never has to resolve the
    /// session from `cwd`.
    static func generateHooks(sessionID: UUID, crowPath: String) -> [String: Any] {
        let sid = sessionID.uuidString
        var hooks: [String: Any] = [:]
        for (cursorKey, crowEvent) in eventMapping {
            let command = "\(crowPath) hook-event --session \(sid) --agent cursor --event \(crowEvent)"
            var entry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5,
            ]
            if asyncCrowEvents.contains(crowEvent) {
                entry["async"] = true
            }
            hooks[cursorKey] = [
                ["hooks": [entry]] as [String: Any]
            ]
        }
        return hooks
    }

    // MARK: - HookConfigWriter Conformance

    /// Write `<worktreePath>/.cursor/hooks.json`, merging so any user-authored
    /// entries for events outside our `eventMapping` survive. Sets the schema
    /// `version` field (Cursor's hooks schema is versioned).
    public func writeHookConfig(
        worktreePath: String,
        sessionID: UUID,
        crowPath: String
    ) throws {
        let cursorDir = (worktreePath as NSString).appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(atPath: cursorDir, withIntermediateDirectories: true)
        let hooksPath = (cursorDir as NSString).appendingPathComponent("hooks.json")

        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: hooksPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        root["version"] = 1

        var existingHooks = root["hooks"] as? [String: Any] ?? [:]
        let ours = Self.generateHooks(sessionID: sessionID, crowPath: crowPath)
        for (eventName, config) in ours {
            existingHooks[eventName] = config
        }
        root["hooks"] = existingHooks

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: hooksPath))
    }

    /// Remove our managed event entries from a worktree's
    /// `.cursor/hooks.json`, preserving user entries. Deletes the file when
    /// nothing but the `version` scaffold would remain.
    public func removeHookConfig(worktreePath: String) {
        let hooksPath = (worktreePath as NSString)
            .appendingPathComponent(".cursor/hooks.json")
        Self.stripManagedEntries(at: hooksPath, requireCrowMarker: false)
    }

    // MARK: - Global-config migration

    /// Strip any Crow-managed entries a prior Crow left in the **global**
    /// `<cursorHome>/hooks.json`. Per-project configs are now the authority
    /// (#829); because Cursor merges global + project and runs both, a
    /// surviving global config would double-fire every event. Only entries
    /// whose command is recognizably Crow's are removed, so a user's own hook
    /// for the same event name is left in place.
    public static func removeManagedGlobalConfig(cursorHome: String) {
        let hooksPath = (cursorHome as NSString).appendingPathComponent("hooks.json")
        stripManagedEntries(at: hooksPath, requireCrowMarker: true)
    }

    /// Shared removal core. When `requireCrowMarker` is true, an event entry is
    /// only removed if its command looks Crow-installed (protects user hooks in
    /// the shared global file); when false (per-worktree file, which we own),
    /// every managed event key is removed.
    private static func stripManagedEntries(at hooksPath: String, requireCrowMarker: Bool) {
        guard let data = FileManager.default.contents(atPath: hooksPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        var changed = false
        for (cursorKey, _) in eventMapping where hooks[cursorKey] != nil {
            if requireCrowMarker && !entryIsCrowManaged(hooks[cursorKey]) { continue }
            hooks.removeValue(forKey: cursorKey)
            changed = true
        }
        guard changed else { return }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        // Nothing meaningful left (empty, or only our `version` scaffold) —
        // remove the file rather than leave a husk.
        let meaningful = root.keys.filter { $0 != "version" }
        if meaningful.isEmpty {
            try? FileManager.default.removeItem(atPath: hooksPath)
            return
        }
        do {
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: hooksPath))
        } catch {
            NSLog("[CursorHookConfigWriter] Failed to rewrite %@: %@",
                  hooksPath, error.localizedDescription)
        }
    }

    /// Whether an event's hook array contains a command Crow installed (either
    /// the per-session form or the legacy global form).
    private static func entryIsCrowManaged(_ value: Any?) -> Bool {
        guard let groups = value as? [[String: Any]] else { return false }
        for group in groups {
            guard let inner = group["hooks"] as? [[String: Any]] else { continue }
            for entry in inner {
                guard let command = entry["command"] as? String else { continue }
                if command.contains(crowCommandMarker) || command.contains(legacyGlobalMarker) {
                    return true
                }
            }
        }
        return false
    }
}
