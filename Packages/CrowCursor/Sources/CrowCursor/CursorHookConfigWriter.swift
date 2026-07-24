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
/// **User-owned entries are respected everywhere.** Unlike Claude's
/// gitignored, local-only `.claude/settings.local.json`, `.cursor/hooks.json`
/// is Cursor's documented **shared project** hooks file — a user may already
/// have committed one. So both write and remove operate at *group* level and
/// key on a Crow marker: a write appends Crow's group (dropping only a prior
/// Crow group, for idempotency) and never clobbers a user's own hook for the
/// same event; a remove strips only Crow's groups. The file is also added to
/// the worktree's `.git/info/exclude` so an unattended `git add -A` can't
/// commit the session-specific config.
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

    public init() {}

    // MARK: - Hook generation

    /// One Crow hook group (`{"hooks": [{command…}]}`) for `crowEvent`, with the
    /// session UUID baked into the command so the server never resolves the
    /// session from `cwd`.
    static func crowGroup(sessionID: UUID, crowEvent: String, crowPath: String) -> [String: Any] {
        let command = "\(crowPath) hook-event --session \(sessionID.uuidString) --agent cursor --event \(crowEvent)"
        var entry: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5,
        ]
        if asyncCrowEvents.contains(crowEvent) {
            entry["async"] = true
        }
        return ["hooks": [entry]]
    }

    // MARK: - HookConfigWriter Conformance

    /// Write `<worktreePath>/.cursor/hooks.json`. For each managed event we drop
    /// any prior Crow group (keeps re-runs idempotent) and append a fresh one,
    /// leaving the user's own groups — and every unmanaged event — untouched.
    /// Sets the schema `version` field and git-excludes the file.
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

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (cursorKey, crowEvent) in Self.eventMapping {
            var groups = hooks[cursorKey] as? [[String: Any]] ?? []
            groups.removeAll { Self.groupIsCrowManaged($0) }
            groups.append(Self.crowGroup(sessionID: sessionID, crowEvent: crowEvent, crowPath: crowPath))
            hooks[cursorKey] = groups
        }
        root["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: hooksPath))

        // Keep the session-specific config out of commits (works for any repo,
        // not just ones that gitignore `.cursor/hooks.json`).
        Self.ensureGitExcluded(worktreePath: worktreePath, pattern: ".cursor/hooks.json")
    }

    /// Remove Crow's hook groups from a worktree's `.cursor/hooks.json`,
    /// preserving a user's own groups (and unmanaged events). Deletes the file
    /// when nothing but the `version` scaffold would remain.
    public func removeHookConfig(worktreePath: String) {
        let hooksPath = (worktreePath as NSString)
            .appendingPathComponent(".cursor/hooks.json")
        Self.stripCrowGroups(at: hooksPath)
    }

    // MARK: - Global-config migration

    /// Strip Crow's hook groups from the **global** `<cursorHome>/hooks.json` a
    /// prior Crow installed. Per-project configs are now the authority (#829);
    /// because Cursor merges global + project and runs both, a surviving global
    /// config would double-fire every event. Only Crow's groups are removed, so
    /// a user's own hooks — even for the same event name — are left in place.
    public static func removeManagedGlobalConfig(cursorHome: String) {
        let hooksPath = (cursorHome as NSString).appendingPathComponent("hooks.json")
        stripCrowGroups(at: hooksPath)
    }

    // MARK: - Group-level helpers

    /// Remove every Crow group from each managed event in `hooksPath`,
    /// preserving user groups; drop an event key that ends up empty and the
    /// whole file when only the `version` scaffold remains. No-op when the file
    /// is absent, unparseable, or already Crow-free.
    private static func stripCrowGroups(at hooksPath: String) {
        guard let data = FileManager.default.contents(atPath: hooksPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        var changed = false
        for (cursorKey, _) in eventMapping {
            guard var groups = hooks[cursorKey] as? [[String: Any]] else { continue }
            let before = groups.count
            groups.removeAll { groupIsCrowManaged($0) }
            if groups.count == before { continue }
            changed = true
            if groups.isEmpty {
                hooks.removeValue(forKey: cursorKey)
            } else {
                hooks[cursorKey] = groups
            }
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

    /// Whether a hook group (`{"hooks": [{command…}]}`) is one Crow installed —
    /// its command shells `crow hook-event … --agent cursor` (matches both the
    /// current `--session` form and the legacy cwd-resolved global form). A
    /// user's own command for the same event won't carry both tokens.
    private static func groupIsCrowManaged(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        for entry in inner {
            guard let command = entry["command"] as? String else { continue }
            if command.contains("hook-event") && command.contains("--agent cursor") {
                return true
            }
        }
        return false
    }

    // MARK: - Git exclude

    /// Best-effort: ensure `pattern` is listed in the worktree's git
    /// `info/exclude` so Crow's runtime config isn't committed. Handles both a
    /// normal `.git` directory and a linked-worktree `.git` file (which points
    /// at a gitdir whose `commondir` holds the shared exclude). Silent on any
    /// failure — the config still works, it just isn't excluded.
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

    /// Resolve the git `info/exclude` path for a worktree, or `nil` when the
    /// directory isn't a git checkout / can't be resolved.
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
