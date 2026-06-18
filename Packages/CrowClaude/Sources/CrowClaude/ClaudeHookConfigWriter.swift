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

    // MARK: - Atlassian MCP (CROW-522)

    /// MCP server name we register for the Atlassian Remote MCP Server.
    static let atlassianMcpServerName = "atlassian"
    /// `env` key carrying the resolved `Authorization` header value. The
    /// `.mcp.json` header references it via `${…}` expansion so the secret lives
    /// only in the owner-only `settings.local.json`, never in `.mcp.json`.
    static let atlassianMcpAuthEnvKey = "ATLASSIAN_MCP_AUTHORIZATION"

    /// Register (or clear) the Atlassian Remote MCP Server for a launched session
    /// (CROW-522). Writes a project-root `.mcp.json` with an `http` server whose
    /// `Authorization` header expands from `${ATLASSIAN_MCP_AUTHORIZATION}`, pre-
    /// trusts it via `enabledMcpjsonServers`, and stores the resolved header value
    /// in the `settings.local.json` `env` block (chmod 0600). Pass `nil` to remove
    /// all three so toggling the MCP off — or a non-Jira session — leaves nothing
    /// stale behind.
    ///
    /// `dirPath` is the worktree path for work/job/review sessions, or the dev
    /// root for the Manager session — the same directory the session launches in,
    /// so Claude Code reads both files.
    public static func writeAtlassianMcpConfig(dirPath: String, resolved: AtlassianMCPResolver.Resolved?) {
        let claudeDir = (dirPath as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        let mcpPath = (dirPath as NSString).appendingPathComponent(".mcp.json")

        // --- settings.local.json: env + enabledMcpjsonServers ---
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        var env = settings["env"] as? [String: Any] ?? [:]
        var enabled = settings["enabledMcpjsonServers"] as? [String] ?? []
        if let resolved {
            env[atlassianMcpAuthEnvKey] = resolved.authorization
            if !enabled.contains(atlassianMcpServerName) { enabled.append(atlassianMcpServerName) }
        } else {
            env.removeValue(forKey: atlassianMcpAuthEnvKey)
            enabled.removeAll { $0 == atlassianMcpServerName }
        }

        if env.isEmpty { settings.removeValue(forKey: "env") } else { settings["env"] = env }
        if enabled.isEmpty {
            settings.removeValue(forKey: "enabledMcpjsonServers")
        } else {
            settings["enabledMcpjsonServers"] = enabled
        }

        if settings.isEmpty {
            try? FileManager.default.removeItem(atPath: settingsPath)
        } else {
            do {
                try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: settingsPath))
                // The env block carries the resolved Basic credential, so restrict
                // the file to owner-only — matching ConfigStore's 0600 on config.json.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: settingsPath)
            } catch {
                NSLog("[ClaudeHookConfigWriter] Failed to write MCP settings to %@: %@",
                      settingsPath, error.localizedDescription)
            }
        }

        // --- .mcp.json: the server definition (no secret — references ${env}) ---
        var mcp: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: mcpPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            mcp = parsed
        }
        var servers = mcp["mcpServers"] as? [String: Any] ?? [:]

        guard let resolved else {
            // Teardown: remove only OUR server entry (its `${env}` reference was
            // just cleared above), and preserve any user-authored servers. Mirror
            // the env/enabledMcpjsonServers handling — only delete the file when
            // nothing of ours or theirs remains. Leaving a dangling `atlassian`
            // entry behind would warn on next launch (missing env var).
            guard servers[atlassianMcpServerName] != nil else { return }
            servers.removeValue(forKey: atlassianMcpServerName)
            if servers.isEmpty {
                mcp.removeValue(forKey: "mcpServers")
            } else {
                mcp["mcpServers"] = servers
            }
            if mcp.isEmpty {
                try? FileManager.default.removeItem(atPath: mcpPath)
            } else {
                if let data = try? JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: mcpPath))
                }
            }
            return
        }

        servers[atlassianMcpServerName] = [
            "type": "http",
            "url": resolved.endpoint,
            "headers": ["Authorization": "${\(atlassianMcpAuthEnvKey)}"],
        ] as [String: Any]
        mcp["mcpServers"] = servers

        do {
            let data = try JSONSerialization.data(withJSONObject: mcp, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: mcpPath))
        } catch {
            NSLog("[ClaudeHookConfigWriter] Failed to write .mcp.json to %@: %@",
                  mcpPath, error.localizedDescription)
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

    /// Find the crow binary, checking common install locations.
    public static func findCrowBinary() -> String? {
        // Check same directory as running executable first (development builds)
        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        let buildDir = execURL.deletingLastPathComponent()
        let devPath = buildDir.appendingPathComponent("crow").path
        if FileManager.default.isExecutableFile(atPath: devPath) {
            return devPath
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
}
