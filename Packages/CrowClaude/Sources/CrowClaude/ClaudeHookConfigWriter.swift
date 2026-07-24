import Foundation
import CrowCore

/// Writes Claude Code's hook configuration into a worktree's
/// `.claude/settings.local.json`. Conforms to `HookConfigWriter` so the main
/// app can treat the configuration step generically; the concrete event list
/// and file format stay local to CrowClaude.
public struct ClaudeHookConfigWriter: HookConfigWriter {

    /// All hook event names we register.
    static let allEvents = [
        "SessionStart", "SessionEnd", "Stop", "StopFailure",
        "Notification", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "UserPromptSubmit",
        "TaskCreated", "TaskCompleted", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact",
    ]

    /// Post-execution events that can safely run async (fire-and-forget).
    /// PreToolUse is intentionally NOT async — it must arrive before
    /// PermissionRequest so the state machine ordering is reliable.
    private static let asyncEvents: Set<String> = [
        "PostToolUse", "PostToolUseFailure",
    ]

    public init() {}

    // MARK: - Generate Hook Configuration

    /// Generate the hooks dictionary for a session.
    static func generateHooks(sessionID: UUID, crowPath: String) -> [String: Any] {
        let sid = sessionID.uuidString
        var hooks: [String: Any] = [:]

        for event in allEvents {
            let command = "\(crowPath) hook-event --session \(sid) --event \(event)"
            var hookEntry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5,
            ]
            if asyncEvents.contains(event) {
                hookEntry["async"] = true
            }
            // Omit matcher to match all occurrences (avoids invalid regex "*")
            hooks[event] = [
                [
                    "hooks": [hookEntry],
                ] as [String: Any]
            ]
        }

        return hooks
    }

    // MARK: - HookConfigWriter Conformance

    /// Write hook configuration to a worktree's .claude/settings.local.json.
    /// Uses a merge strategy: preserves user settings, only updates our hook entries.
    public func writeHookConfig(
        worktreePath: String,
        sessionID: UUID,
        crowPath: String
    ) throws {
        let claudeDir = (worktreePath as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")

        // Read existing settings if present
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        // Get existing hooks and preserve any non-crow-managed entries
        var existingHooks = settings["hooks"] as? [String: Any] ?? [:]

        // Generate our hooks
        let ourHooks = Self.generateHooks(sessionID: sessionID, crowPath: crowPath)

        // Merge: our hooks overwrite matching event names, user hooks for other events are preserved
        for (eventName, hookConfig) in ourHooks {
            existingHooks[eventName] = hookConfig
        }

        settings["hooks"] = existingHooks

        // Write back
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: settingsPath))
    }

    // MARK: - Gateway env

    /// Keys we manage inside the settings `env` block (CROW-402).
    private static let gatewayEnvKeys = ["ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS"]

    /// Write (or clear) the AI-gateway env vars in a directory's
    /// `.claude/settings.local.json` `env` block, merging with existing settings.
    ///
    /// Claude Code reads this `env` block on every launch, so this makes the
    /// gateway survive manual `claude` re-runs in the terminal — not just the
    /// initial launch (CROW-402). Pass a resolved gateway to set the vars, or
    /// `nil` to remove them (so switching a workspace off its gateway clears the
    /// stale values rather than leaving them behind).
    ///
    /// `dirPath` is the worktree path for work/job/review sessions, or the dev
    /// root for the Manager session.
    public static func writeGatewayEnv(dirPath: String, resolved: GatewayResolver.Resolved?) {
        let claudeDir = (dirPath as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")

        // Read existing settings if present.
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var env = settings["env"] as? [String: Any] ?? [:]
        if let resolved {
            env["ANTHROPIC_BASE_URL"] = resolved.baseURL
            env["ANTHROPIC_CUSTOM_HEADERS"] = resolved.customHeaders
        } else {
            for key in gatewayEnvKeys { env.removeValue(forKey: key) }
        }

        if env.isEmpty {
            settings.removeValue(forKey: "env")
        } else {
            settings["env"] = env
        }

        // Nothing to write and no file to clean up.
        if settings.isEmpty && !FileManager.default.fileExists(atPath: settingsPath) {
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath))
            // The env block can carry a resolved bearer token, so restrict the
            // file to owner-only — matching ConfigStore's 0600 on config.json.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: settingsPath)
        } catch {
            NSLog("[ClaudeHookConfigWriter] Failed to write gateway env to %@: %@",
                  settingsPath, error.localizedDescription)
        }
    }

    // MARK: - Corveil worker-run env

    /// Inject the Corveil runner credentials + run identity into a scratch
    /// workdir's `.claude/settings.local.json` `env` block (corveil/crow#801).
    ///
    /// A repo-less worker run executes in a throwaway scratch dir with no
    /// `corveil login` state, so the agent needs `CORVEIL_URL` + the scoped
    /// `CORVEIL_API_KEY` to call `corveil worker-run mcp-call` / `corveil ask`.
    /// It also needs the run id + worker id so its write-back calls target the
    /// right run under the same bearer identity Crow claimed with. These land in
    /// the same 0600 `env` block `writeGatewayEnv` uses (the file carries an org
    /// secret) and the scratch dir is wiped on finish — so the key never
    /// persists. Empty values are skipped so a blank var never shadows ambient
    /// state.
    ///
    /// Returns `true` only when the secret file was written and locked down to
    /// 0600. The caller (`SessionService.runWorkerRun`) treats `false` as fatal —
    /// launching an agent without the injected credentials would leave it unable
    /// to write back (or reaching for ambient creds), so the run is failed
    /// instead (corveil/crow#801 review).
    @discardableResult
    public static func writeCorveilRunEnv(
        dirPath: String,
        corveilURL: String,
        apiKey: String,
        runID: String,
        workerID: String
    ) -> Bool {
        let claudeDir = (dirPath as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")

        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var env = settings["env"] as? [String: Any] ?? [:]
        if !corveilURL.isEmpty { env["CORVEIL_URL"] = corveilURL }
        if !apiKey.isEmpty { env["CORVEIL_API_KEY"] = apiKey }
        env["CROW_WORKER_RUN_ID"] = runID
        env["CROW_WORKER_ID"] = workerID
        settings["env"] = env

        do {
            try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath))
            // The env block carries the scoped CORVEIL_API_KEY — restrict to
            // owner-only, matching writeGatewayEnv / ConfigStore's 0600.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: settingsPath)
            return true
        } catch {
            NSLog("[ClaudeHookConfigWriter] Failed to write Corveil run env to %@: %@",
                  settingsPath, error.localizedDescription)
            return false
        }
    }

    /// Remove our hook entries from a worktree's settings.local.json, preserving user settings.
    public func removeHookConfig(worktreePath: String) {
        let settingsPath = (worktreePath as NSString)
            .appendingPathComponent(".claude/settings.local.json")

        guard let data = FileManager.default.contents(atPath: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            return
        }

        // Remove our managed event entries
        for event in Self.allEvents {
            hooks.removeValue(forKey: event)
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        // If settings is now empty, remove the file
        if settings.isEmpty {
            do {
                try FileManager.default.removeItem(atPath: settingsPath)
            } catch {
                NSLog("[ClaudeHookConfigWriter] Failed to remove empty settings file at %@: %@",
                      settingsPath, error.localizedDescription)
            }
        } else {
            do {
                let updatedData = try JSONSerialization.data(
                    withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: settingsPath))
            } catch {
                NSLog("[ClaudeHookConfigWriter] Failed to write updated settings to %@: %@",
                      settingsPath, error.localizedDescription)
            }
        }
    }

    // MARK: - Find crow Binary

    /// Resolve the running app's own `crow` CLI — the bundled binary in a
    /// release `.app` (`Contents/MacOS/crow`), or `.build/{config}/crow` in
    /// dev. Does not consult `{devRoot}/.claude/bin/crow`; use that for
    /// agent-facing resolution via `findCrowBinary(devRoot:)`.
    public static func appCrowBinary() -> String? {
        // Same directory as the running executable (dev + release bundles).
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let sibling = execURL.deletingLastPathComponent().appendingPathComponent("crow").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }

        // Walk the user's login-shell PATH (same order as CodingAgent.findBinary).
        if let found = ShellEnvironment.shared.findExecutable("crow") {
            return found
        }

        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/crow").path,
            "/usr/local/bin/crow",
            "/opt/homebrew/bin/crow",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Find the `crow` binary agents and hook configs should invoke. Prefers
    /// `{devRoot}/.claude/bin/crow` when scaffolded and executable (CROW-552),
    /// then falls back to `appCrowBinary()` and common install locations.
    public static func findCrowBinary(devRoot: String? = nil) -> String? {
        if let devRoot {
            let symlink = (devRoot as NSString).appendingPathComponent(".claude/bin/crow")
            if FileManager.default.isExecutableFile(atPath: symlink) {
                return symlink
            }
        }
        return appCrowBinary()
    }
}
