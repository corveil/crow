import Foundation
import CrowCore

/// Writes Google Antigravity's per-worktree hook configuration into
/// `<worktree>/.agents/hooks.json`, with the Crow session UUID baked into every
/// command (`hook-event --session <uuid> --agent antigravity`). Structurally a
/// near-clone of `CursorHookConfigWriter` — one config per session directory,
/// no global config, per-session **UUID** resolution — because Antigravity's
/// hooks are Claude-Code-style (JSON on stdin, reply on stdout, exit-code
/// semantics, the `PreToolUse`/`PostToolUse` tool vocabulary), which is what
/// lets the `HookConfigWriter` / `StateSignalSource` pair work rather than being
/// a `cwd`-scoped fallback (#860).
///
/// **Why per-worktree with UUID, not global `~/.gemini/config/`.** Antigravity
/// reads hooks from both the global `~/.gemini/config/hooks.json` and the
/// workspace `.agents/hooks.json`; if it merges and runs both (as Cursor does),
/// a surviving global config would double-fire every event. Per-worktree-only
/// sidesteps that, bakes the session UUID into the command (so the server never
/// guesses the session from `cwd` — which the Manager, running in the un-worktree
/// devRoot, defeats), and `LaunchScaffold` calls `removeManagedGlobalConfig` to
/// migrate users off any global config a prior Crow installed.
///
/// **`.agents/hooks.json` is a shared workspace file.** Like Cursor's
/// `.cursor/hooks.json` (and unlike Claude's gitignored, local-only
/// `.claude/settings.local.json`), a user may already track a committed
/// `.agents/hooks.json`. So this writer inherits Cursor's guarantees verbatim:
/// group-level Crow-marker preservation (a user's own hook for the same event is
/// never clobbered), an untracked file is git-excluded so it isn't committed,
/// and if the repo already **commits** `.agents/hooks.json` the write is skipped
/// entirely (logged) rather than poison the shared repo with a machine-local
/// crow path + dead session UUID.
///
/// The JSON shape is Claude-Code-style (PascalCase event keys, no top-level
/// `version`): `{"hooks": {"PreToolUse": [{"hooks": [{type,command,…}]}], …}}`.
public struct AntigravityHookConfigWriter: HookConfigWriter {

    /// The lifecycle events documented for `agy` v1.1.7 that Crow observes,
    /// mapped 1:1 to their Crow-canonical (= native, PascalCase) event name.
    /// `PreInvocation`/`PostInvocation` are Antigravity's turn-boundary hooks
    /// (Claude's `UserPromptSubmit`/`SessionStart` analogue); `Stop` carries
    /// `fullyIdle` and is the authoritative done signal (see
    /// `AntigravitySignalSource`).
    static let events: [String] = [
        "PreInvocation",
        "PostInvocation",
        "PreToolUse",
        "PostToolUse",
        "Stop",
    ]

    /// Post-execution events safe to run async (fire-and-forget). `Stop` stays
    /// synchronous because its state-transition timing drives the UI;
    /// `PreToolUse`/`PreInvocation` stay sync so they arrive in order.
    private static let asyncEvents: Set<String> = ["PostToolUse", "PostInvocation"]

    public init() {}

    // MARK: - Hook generation

    /// One Crow hook group (`{"hooks": [{command…}]}`) for `event`, with the
    /// session UUID baked into the command.
    static func crowGroup(sessionID: UUID, event: String, crowPath: String) -> [String: Any] {
        // Antigravity runs this string through a shell, so quote the crow path —
        // `findCrowBinary` prefers `{devRoot}/.claude/bin/crow` and devRoot is
        // user-chosen (`/Users/x/My Projects/…` would otherwise split the command
        // and silently stop every hook from firing).
        let command = "\(AntigravityLaunchArgs.shellQuote(crowPath)) hook-event --session \(sessionID.uuidString) --agent antigravity --event \(event)"
        var entry: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5,
        ]
        if asyncEvents.contains(event) {
            entry["async"] = true
        }
        return ["hooks": [entry]]
    }

    // MARK: - HookConfigWriter conformance

    /// Write `<worktreePath>/.agents/hooks.json`. For each managed event we drop
    /// any prior Crow group (keeps re-runs idempotent) and append a fresh one,
    /// leaving the user's own groups — and every unmanaged event — untouched.
    /// Git-excludes the file.
    public func writeHookConfig(
        worktreePath: String,
        sessionID: UUID,
        crowPath: String
    ) throws {
        let agentsDir = (worktreePath as NSString).appendingPathComponent(".agents")
        let hooksPath = (agentsDir as NSString).appendingPathComponent("hooks.json")

        // If the repo *tracks* `.agents/hooks.json`, refuse to write into it.
        // `.git/info/exclude` has no effect on already-tracked files, so an
        // unattended `.job` doing `git add -A` would commit Crow's absolute
        // crow-path + dead session UUID into the shared repo, breaking every
        // teammate's tool calls. Better to lose state detection for this one
        // worktree than to poison the repo. Checked unconditionally (not gated on
        // the file existing) so a tracked-but-`rm`'d file is still caught.
        if Self.isGitTracked(worktreePath: worktreePath, relativePath: ".agents/hooks.json") {
            NSLog("[AntigravityHookConfigWriter] %@/.agents/hooks.json is git-tracked; not writing Crow's session hooks into a committed file. Gitignore/untrack it to enable hook-based state detection for this worktree.", worktreePath)
            return
        }

        try FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)

        // If the file EXISTS but doesn't parse (a torn concurrent write, a
        // hand-edit with a syntax error), bail rather than start from `[:]` and
        // overwrite the user's own hook groups.
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: hooksPath) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[AntigravityHookConfigWriter] %@ exists but is unparseable; leaving it untouched (would otherwise drop the user's own hook groups)", hooksPath)
                return
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in Self.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.removeAll { Self.groupIsCrowManaged($0) }
            groups.append(Self.crowGroup(sessionID: sessionID, event: event, crowPath: crowPath))
            hooks[event] = groups
        }
        root["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // Atomic (temp + rename): a crash mid-write would otherwise leave a
        // truncated file that the unparseable-guard then refuses to touch,
        // silently disabling this worktree's hook-based state detection forever.
        try data.write(to: URL(fileURLWithPath: hooksPath), options: [.atomic])

        // Keep the session-specific config out of commits (works for any repo,
        // not just ones that gitignore `.agents/hooks.json`). One-way by design:
        // the pattern is a repo-level ignore rule shared by every worktree, so
        // `removeHookConfig` must NOT pull it back out — a sibling worktree's
        // still-live session would otherwise lose the protection.
        Self.ensureGitExcluded(worktreePath: worktreePath, pattern: ".agents/hooks.json")
    }

    /// Remove Crow's hook groups from a worktree's `.agents/hooks.json`,
    /// preserving a user's own groups (and unmanaged events). Deletes the file
    /// when nothing meaningful would remain.
    public func removeHookConfig(worktreePath: String) {
        let hooksPath = (worktreePath as NSString)
            .appendingPathComponent(".agents/hooks.json")
        Self.stripCrowGroups(at: hooksPath)
    }

    // MARK: - Global-config migration

    /// Strip Crow's hook groups from the **global** `<geminiConfigHome>/hooks.json`
    /// a prior Crow (or a future scope change) may have installed. Per-worktree
    /// configs are the authority; because Antigravity may merge global + workspace
    /// and run both, a surviving global config would double-fire every event.
    /// Only Crow's groups are removed — a user's own hooks survive. `geminiConfigHome`
    /// is typically `~/.gemini/config`.
    public static func removeManagedGlobalConfig(geminiConfigHome: String) {
        let hooksPath = (geminiConfigHome as NSString).appendingPathComponent("hooks.json")
        stripCrowGroups(at: hooksPath)
    }

    // MARK: - Group-level helpers

    /// Remove every Crow group from each managed event in `hooksPath`, preserving
    /// user groups; drop an event key that ends up empty and the whole file when
    /// only unmanaged scaffold remains. No-op when the file is absent,
    /// unparseable, or already Crow-free.
    private static func stripCrowGroups(at hooksPath: String) {
        guard let data = FileManager.default.contents(atPath: hooksPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            return
        }

        var changed = false
        for event in events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            let before = groups.count
            groups.removeAll { groupIsCrowManaged($0) }
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
            NSLog("[AntigravityHookConfigWriter] Failed to rewrite %@: %@",
                  hooksPath, error.localizedDescription)
        }
    }

    /// Whether a hook group (`{"hooks": [{command…}]}`) is one Crow installed —
    /// its command shells `crow hook-event … --agent antigravity`. A user's own
    /// command for the same event won't carry both tokens.
    private static func groupIsCrowManaged(_ group: [String: Any]) -> Bool {
        guard let inner = group["hooks"] as? [[String: Any]] else { return false }
        for entry in inner {
            guard let command = entry["command"] as? String else { continue }
            if command.contains("hook-event") && command.contains("--agent antigravity") {
                return true
            }
        }
        return false
    }

    // MARK: - Git-tracked probe (mirrors CursorHookConfigWriter)

    /// Cache of `(worktreePath, relativePath) → tracked?`, probed at most once per
    /// process. Guarded by `trackedCacheLock`.
    private nonisolated(unsafe) static var trackedCache: [String: Bool] = [:]
    private static let trackedCacheLock = NSLock()

    /// Best-effort: whether `relativePath` is tracked in the worktree's git index
    /// (`git ls-files --error-unmatch`). Returns false on any error (no git, not a
    /// repo, untracked) — the safe default is "untracked", so a normal worktree
    /// still gets its hooks written. Bounded by a short timeout; cached per
    /// (worktree, path).
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

    // MARK: - Git exclude (mirrors CursorHookConfigWriter)

    /// Best-effort: ensure `pattern` is listed in the worktree's git
    /// `info/exclude` so Crow's runtime config isn't committed. Handles both a
    /// normal `.git` directory and a linked-worktree `.git` file. Silent on any
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
        // The `info/exclude` in the *common* dir applies to all worktrees.
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
