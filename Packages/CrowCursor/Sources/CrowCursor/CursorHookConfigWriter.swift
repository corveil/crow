import Foundation
import CrowCore

/// Writes hook configuration that Cursor picks up. Cursor reads hooks from
/// `~/.cursor/hooks.json` (override via `CURSOR_CONFIG_DIR`) regardless of
/// which directory `agent` is invoked from — global, not per-worktree.
/// Per-worktree project hooks at `<project>/.cursor/hooks.json` are
/// supported by Cursor but deferred to a follow-up; MVP is global-only,
/// matching Codex's scope.
///
/// Because `HookConfigWriter`'s per-session API doesn't fit Cursor's global
/// model, the per-session methods are intentionally no-ops. Real work
/// happens via the static `installGlobalConfig` call invoked once at app
/// launch.
///
/// Cursor's native event names are camelCase (`preToolUse`, `stop`) but
/// it documents exit-code 0/2 semantics and the `CLAUDE_PROJECT_DIR` alias
/// as "matching Claude Code behavior for compatibility." We collapse the
/// camelCase ↔ PascalCase mapping into this writer: the JSON key uses
/// Cursor's camelCase form, and the `--event <Name>` argument inside the
/// command uses the Crow-canonical PascalCase form. That lets
/// `CursorSignalSource` share Claude/Codex's event vocabulary verbatim.
public struct CursorHookConfigWriter: HookConfigWriter {

    /// Curated event subset matching what `CodexSignalSource` already
    /// handles, plus `Notification` (mapped from `afterAgentResponse` as a
    /// safety net for headless `agent -p` mode where `stop` may not fire).
    /// Keyed by Cursor's camelCase event name; value is the Crow-canonical
    /// PascalCase event name written into the `--event` argument.
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

    public init() {}

    // MARK: - HookConfigWriter Conformance (no-ops)

    /// No-op. Cursor hooks are global, not per-worktree — see
    /// `installGlobalConfig`. A future revision may layer in per-project
    /// `<worktree>/.cursor/hooks.json` for finer-grained state, but MVP
    /// stays global-only.
    public func writeHookConfig(worktreePath: String, sessionID: UUID, crowPath: String) throws {}

    /// No-op. Cursor's global `hooks.json` stays in place when individual
    /// sessions are deleted; it serves all sessions.
    public func removeHookConfig(worktreePath: String) {}

    // MARK: - Global Configuration

    /// Build the hooks dict in the schema Cursor expects. Each Cursor
    /// camelCase event key maps to a command invoking
    /// `<crow> hook-event --agent cursor --event <PascalName>` with no
    /// `--session` flag — the crow server resolves the session from `cwd`
    /// in the payload.
    static func generateHooks(crowPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for (cursorKey, crowEvent) in eventMapping {
            let command = "\(crowPath) hook-event --agent cursor --event \(crowEvent)"
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

    /// Install or refresh `<cursorHome>/hooks.json` with Crow's hook
    /// commands. Idempotent — re-running just rewrites the same content.
    /// Preserves any user-authored entries for events Crow doesn't manage.
    public static func installGlobalConfig(cursorHome: String, crowPath: String) throws {
        try FileManager.default.createDirectory(atPath: cursorHome, withIntermediateDirectories: true)
        let hooksPath = (cursorHome as NSString).appendingPathComponent("hooks.json")

        // Read existing hooks.json if present so user-authored entries for
        // events outside our `eventMapping` survive.
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
}
