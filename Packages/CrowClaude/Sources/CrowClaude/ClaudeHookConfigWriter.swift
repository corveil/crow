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
    /// PreToolUse stays non-async so the agent waits for its hook process to
    /// exit before firing the next hook — which keeps PreToolUse *accepted* by
    /// the daemon ahead of the following PermissionRequest.
    ///
    /// Note (#903): pre-fire-and-forget, non-async also gave end-to-end *apply*
    /// ordering — the hook process blocked on the daemon's reply, written only
    /// after the transition was applied, so event N was applied before N+1 was
    /// sent. `crow hook-event` no longer waits for that reply, and the daemon
    /// applies hook-events on independently-scheduled `MainActor` tasks
    /// (`SocketServer` fans each connection out concurrently), so accept order
    /// no longer implies apply order. Keeping PreToolUse non-async still narrows
    /// the reorder window to that MainActor scheduling race (vs. also racing the
    /// writes if it were async).
    ///
    /// Known limitation until the fix lands: a PreToolUse/PermissionRequest
    /// inversion can show the wrong card state. Two directions, and they are not
    /// equally benign:
    ///   - PostToolUse racing a *later* PreToolUse can strand the card at
    ///     `.waiting` while the agent is actively working — this self-corrects,
    ///     because the agent keeps emitting events (the next PreToolUse/Stop
    ///     fixes it).
    ///   - PreToolUse applied *after* PermissionRequest blanket-clears the
    ///     permission badge and sets `.working` — and this does NOT self-correct.
    ///     The agent is parked at the prompt, so no further hook fires until the
    ///     user answers. The only backstop is a separate `Notification` carrying
    ///     `notification_type == "permission_prompt"`, which re-raises the badge
    ///     (`ClaudeHookSignalSource`); that field is read verbatim from the
    ///     payload, never synthesized, so on any Claude build that doesn't emit
    ///     it the card can read `.working` for the whole prompt and Crow never
    ///     surfaces "waiting". This is Claude-specific — Cursor keeps a
    ///     `PermissionRequest` case for parity but doesn't emit it, so the
    ///     permission-badge case can't arise there.
    ///
    /// A pure client-side signal source can't reliably tell "this PreToolUse is
    /// the one the pending prompt is for" (the event carries no ordering key and
    /// `PermissionRequest` carries no verified tool identity), so the correct fix
    /// is per-session server-side sequencing of hook-event application — the
    /// daemon-side follow-up scoped out of #903 (see docs/agent-harness-matrix.md
    /// "Hook async delivery"). The reorder *window* is a few milliseconds; the
    /// resulting wrong state persists as described above.
    private static let asyncEvents: Set<String> = [
        "PostToolUse", "PostToolUseFailure",
    ]

    public init() {}

    // MARK: - Generate Hook Configuration

    /// The exact hook command Crow writes. Single source of truth shared with
    /// `ClaudeHookRepair`, which both parses this shape to decide what it owns
    /// and re-emits it when repairing a stale entry (#897).
    ///
    /// `crowPath` is shell-quoted: Claude runs hook commands through `/bin/sh
    /// -c`, so an unquoted dev root containing a space (`/Users/x/My Dev`)
    /// silently broke all 17 hooks. Matches `CursorHookConfigWriter` and
    /// `AntigravityHookConfigWriter`, which already quote for this reason.
    static func hookCommand(crowPath: String, sessionID: UUID, event: String) -> String {
        "\(ClaudeLaunchArgs.shellQuote(crowPath)) hook-event --session \(sessionID.uuidString) --event \(event)"
    }

    /// Generate the hooks dictionary for a session.
    static func generateHooks(sessionID: UUID, crowPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]

        for event in allEvents {
            let command = hookCommand(crowPath: crowPath, sessionID: sessionID, event: event)
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
            CrowLog.info("[ClaudeHookConfigWriter] Failed to write gateway env to \(settingsPath): \(error.localizedDescription)")
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
                CrowLog.info("[ClaudeHookConfigWriter] Failed to remove empty settings file at \(settingsPath): \(error.localizedDescription)")
            }
        } else {
            do {
                let updatedData = try JSONSerialization.data(
                    withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
                try updatedData.write(to: URL(fileURLWithPath: settingsPath))
            } catch {
                CrowLog.info("[ClaudeHookConfigWriter] Failed to write updated settings to \(settingsPath): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Find crow Binary

    /// Resolve the running app's own `crow` CLI — the bundled binary in a
    /// release `.app` (`Contents/MacOS/crow`), or `.build/{config}/crow` in
    /// dev. Does not consult `{devRoot}/.claude/bin/crow`; use that for
    /// agent-facing resolution via `resolveCrowBinary(devRoot:)`.
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
    ///
    /// Read-only — it never *creates* the symlink, so a dev build whose link is
    /// missing or dangling falls through to a `.build/…/debug/crow` path that
    /// dies with the worktree it was built in. Anything whose result is written
    /// to disk must use `resolveCrowBinary` instead (#897); this stays for
    /// callers that only need to *locate* a crow to run right now.
    public static func findCrowBinary(devRoot: String? = nil) -> String? {
        if let devRoot {
            let symlink = (devRoot as NSString).appendingPathComponent(".claude/bin/crow")
            if FileManager.default.isExecutableFile(atPath: symlink) {
                return symlink
            }
        }
        return appCrowBinary()
    }

    /// Materialize `{devRoot}/.claude/bin/crow` → `appCrowPath ?? appCrowBinary()`,
    /// returning the **link** path once it resolves to an executable (`nil`
    /// otherwise). Idempotent; safe to call on every launch.
    ///
    /// The link is the stable anchor that makes hook commands survive worktree
    /// churn: only its target moves when a dev build is rebuilt elsewhere, so
    /// one relink at boot heals every `settings.local.json` at once (#897).
    ///
    /// Two deliberate behaviors, both load-bearing:
    /// - A link already pointing at `target` is left alone rather than
    ///   unlink+relink'd — that window is one where a concurrently firing hook
    ///   sees ENOENT.
    /// - A **non-symlink** `crow` at that path is never replaced. We only ever
    ///   own symlinks here; a real file is the user's.
    ///
    /// `appCrowPath` is injectable for tests. All errors are logged and
    /// swallowed — this is best-effort and must never fail a launch.
    @discardableResult
    public static func ensureCrowCLISymlink(devRoot: String, appCrowPath: String? = nil) -> String? {
        let binDir = (devRoot as NSString).appendingPathComponent(".claude/bin")
        let link = (binDir as NSString).appendingPathComponent("crow")
        return materializeCrowSymlink(at: link, target: appCrowPath ?? appCrowBinary())
    }

    /// `{HOME}/.local/share/crow/bin/crow` — the stable link used when the dev
    /// root's own cannot be made (unwritable, or no dev root at all).
    ///
    /// `~/.local/share/crow/` is already Crow's state directory (the daemon
    /// socket lives there), so this introduces no new convention. It exists so
    /// `resolveCrowBinary` always has *some* stable path to emit and never has
    /// to fall back to a `.build/` product (#915) — the failure that put a dead
    /// worktree's binary into every hook command in #897.
    static func stableFallbackLinkPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/crow/bin/crow").path
    }

    /// Point `link` at `target`, creating the parent directory as needed.
    /// Returns the **link** path once it resolves to an executable, `nil`
    /// otherwise. Idempotent; safe to call on every launch.
    ///
    /// Two deliberate behaviors, both load-bearing:
    /// - A link already pointing at `target` is left alone rather than
    ///   unlink+relink'd — that window is one where a concurrently firing hook
    ///   sees ENOENT.
    /// - A **non-symlink** `crow` at that path is never replaced. We only ever
    ///   own symlinks here; a real file is the user's.
    ///
    /// All errors are logged and swallowed — this is best-effort and must never
    /// fail a launch.
    private static func materializeCrowSymlink(at link: String, target resolved: String?) -> String? {
        let fm = FileManager.default
        let binDir = (link as NSString).deletingLastPathComponent

        guard let target = resolved, fm.isExecutableFile(atPath: target) else {
            // Drop a link we can no longer back, so a broken pointer doesn't
            // shadow a working PATH install.
            if let attrs = try? fm.attributesOfItem(atPath: link),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                try? fm.removeItem(atPath: link)
            }
            if let resolved {
                CrowLog.info("[ClaudeHookConfigWriter] app crow binary not executable at \(resolved) — skipping symlink")
            }
            return nil
        }

        // Unlike Scaffolder, this can run against a dev root no scaffold pass
        // has touched yet (a `crow send` before the first boot scaffold), so
        // create the directory rather than assuming it.
        do {
            try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        } catch {
            CrowLog.info("[ClaudeHookConfigWriter] could not create bin dir \(binDir): \(error.localizedDescription)")
            return nil
        }

        // Drive off attributesOfItem, not fileExists — the latter follows
        // symlinks, so a dangling `crow` link (target moved/deleted) looks
        // absent and we'd skip removal, then createSymbolicLink hits EEXIST.
        if let attrs = try? fm.attributesOfItem(atPath: link) {
            guard (attrs[.type] as? FileAttributeType) == .typeSymbolicLink else {
                CrowLog.info("[ClaudeHookConfigWriter] crow exists at \(link) but is not a symlink — leaving alone")
                return fm.isExecutableFile(atPath: link) ? link : nil
            }
            if (try? fm.destinationOfSymbolicLink(atPath: link)) == target {
                return link
            }
            try? fm.removeItem(atPath: link)
        }

        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            return link
        } catch {
            CrowLog.info("[ClaudeHookConfigWriter] failed to symlink \(link) -> \(target): \(error.localizedDescription)")
            return nil
        }
    }

    /// The `crow` path to bake into a hook command (or any other file on disk).
    ///
    /// **Never returns a `.build/…` path.** A build product belongs to whichever
    /// worktree the running daemon was built in; when that worktree is reaped the
    /// command dies with it, every hook event fails in `/bin/sh` before `crow`
    /// runs, and the session silently records no telemetry. That is the root
    /// cause of #897, and — because a worktree session also loads its *main
    /// clone's* settings — one such command breaks every session on the repo
    /// (#915).
    ///
    /// Resolution order, each step a stable path that survives a rebuild:
    ///   1. `{devRoot}/.claude/bin/crow` (also on the agent's PATH)
    ///   2. `~/.local/share/crow/bin/crow`, for an unwritable or absent dev root
    ///   3. `appCrowBinary()`, but only when it is not itself a build product —
    ///      i.e. a real install on PATH or in a release `.app`
    ///   4. `nil`
    ///
    /// Returning `nil` means the caller writes no hook block at all. That costs
    /// telemetry for the session, but it is strictly better than writing a
    /// command that is already broken: a dangling block outlives the session,
    /// and every worktree of the repo inherits its errors. Deliberately not a
    /// `precondition` — crashing the daemon would be worse than either.
    ///
    /// `appCrowPath` and `stableFallbackLink` are injectable for tests, which
    /// must not write into the real `~/.local/share` (ADR 0012).
    public static func resolveCrowBinary(
        devRoot: String?, appCrowPath: String? = nil, stableFallbackLink: String? = nil
    ) -> String? {
        if let devRoot, let link = ensureCrowCLISymlink(devRoot: devRoot, appCrowPath: appCrowPath) {
            return link
        }
        let target = appCrowPath ?? appCrowBinary()
        let fallbackLink = stableFallbackLink ?? stableFallbackLinkPath()
        if let link = materializeCrowSymlink(at: fallbackLink, target: target) {
            CrowLog.info(
                "[ClaudeHookConfigWriter] \(devRoot ?? "<no dev root>")/.claude/bin is not usable"
                + " — writing hook commands against \(link) instead.")
            return link
        }
        // Both stable links failed. Only hand back the raw binary if it is one
        // that will still exist after the next rebuild.
        if let target, !target.contains("/.build/") {
            return target
        }
        CrowLog.error(
            "[ClaudeHookConfigWriter] no stable crow path available"
            + " (candidate \(target ?? "<none>") is a build product); writing no hook config."
            + " Check that \(devRoot ?? "<no dev root>")/.claude/bin or"
            + " \(fallbackLink) is writable.")
        return nil
    }
}
