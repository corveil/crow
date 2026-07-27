import Foundation
import CrowCore

/// Writes Google Antigravity's per-worktree hook configuration into
/// `<worktree>/.agents/hooks.json`, with the Crow session UUID baked into every
/// command (`hook-event --session <uuid> --agent antigravity`).
///
/// **Schema — Antigravity's own, not Claude's.** Verified against
/// [`antigravity.google/docs/hooks`](https://antigravity.google/docs/hooks): the
/// file is a map of **named groups** → event configs, *not* Claude's
/// `{"hooks": {Event: […]}}`. Crow owns exactly one named group (`"crow"`) and
/// leaves every other group untouched:
///
/// ```json
/// {
///   "crow": {
///     "PreInvocation":  [ {"type":"command","command":"…","timeout":5} ],
///     "PostInvocation": [ {"type":"command","command":"…","timeout":5} ],
///     "PostToolUse":    [ {"matcher":"*","hooks":[{"type":"command","command":"…","timeout":5}]} ],
///     "Stop":           [ {"type":"command","command":"…","timeout":5} ]
///   }
/// }
/// ```
///
/// Tool events (`PostToolUse`) wrap handlers in `{matcher, hooks:[…]}` with the
/// catch-all `"*"` matcher; invocation/`Stop` events list handlers **directly**
/// under the event key (matcher ignored). There is **no `async` field** in
/// Antigravity's handler schema — declaring one risks a parse failure.
///
/// **`PreToolUse` is deliberately not registered.** Antigravity's own bundled
/// plugin (vibe-island) registers `PreInvocation`/`PostInvocation`/`PostToolUse`/
/// `Stop` and skips `PreToolUse`, because `PreToolUse` demands a strict stdout
/// verdict (`{"decision":"allow"|"deny"|"ask"|"force_ask"}`) and a mis-shaped
/// reply denies **every** tool call (see cmux #5358). Crow's hooks are
/// observational, so we stay off that gate and detect tool activity from
/// `PostToolUse` (whose reply is a harmless `{}`).
///
/// **Every command emits its own stdout verdict.** Antigravity reads the hook's
/// stdout as JSON. `crow hook-event` is observational and may print a JSON-RPC
/// error on failure, so each command **suppresses** hook-event's output and then
/// `printf '{}'`s the empty-object verdict itself — the documented no-op reply
/// for `PostToolUse`/`PreInvocation`/`PostInvocation`, and a non-`continue` reply
/// for `Stop` (i.e. "allow the agent to stop"). Using `;` (not `&&`) plus the
/// trailing `printf` guarantees the verdict is emitted and the hook exits 0 even
/// when hook-event fails — so a Crow hook can never block a tool or loop the
/// agent.
///
/// **`.agents/hooks.json` is a shared workspace file** (like Cursor's
/// `.cursor/hooks.json`), so this writer keeps Cursor's protections: a
/// git-tracked config is left untouched (never poison a committed file), an
/// untracked one is git-excluded, and a torn/unparseable file is bailed on
/// rather than clobbered. Crow only ever writes/removes its own `"crow"` group,
/// so a user's other named groups survive verbatim.
public struct AntigravityHookConfigWriter: HookConfigWriter {

    /// Crow's named group key. Antigravity's config maps named groups → events;
    /// Crow owns exactly this one group (a user naming their own group `"crow"`
    /// is a documented collision — Crow's write wins for that key only).
    static let groupKey = "crow"

    /// Tool-scoped events — wrapped in `{matcher, hooks:[…]}`. Mirrors
    /// vibe-island; `PreToolUse` is intentionally excluded (see type doc).
    static let toolEvents = ["PostToolUse"]

    /// Invocation / stop events — handlers listed directly under the event key
    /// (no matcher, no `hooks` wrapper).
    static let directEvents = ["PreInvocation", "PostInvocation", "Stop"]

    /// All events Crow registers (for strip/round-trip helpers).
    static var allEvents: [String] { toolEvents + directEvents }

    public init() {}

    // MARK: - Command + group generation

    /// The shell command for `event`: forward to `crow hook-event`, suppress its
    /// output, then emit the `{}` stdout verdict and exit 0.
    static func crowCommand(sessionID: UUID, event: String, crowPath: String) -> String {
        // Quote the crow path — devRoot is user-chosen (`/Users/x/My Projects/…`
        // would otherwise split the command).
        "\(AntigravityLaunchArgs.shellQuote(crowPath)) hook-event --session \(sessionID.uuidString) --agent antigravity --event \(event) >/dev/null 2>&1; printf '{}'"
    }

    /// One `{type, command, timeout}` handler object.
    private static func handler(sessionID: UUID, event: String, crowPath: String) -> [String: Any] {
        [
            "type": "command",
            "command": crowCommand(sessionID: sessionID, event: event, crowPath: crowPath),
            "timeout": 5,
        ]
    }

    /// Build Crow's `"crow"` group: direct handlers for invocation/Stop events,
    /// `{matcher:"*", hooks:[…]}` for tool events.
    static func crowGroup(sessionID: UUID, crowPath: String) -> [String: Any] {
        var group: [String: Any] = [:]
        for event in directEvents {
            group[event] = [handler(sessionID: sessionID, event: event, crowPath: crowPath)]
        }
        for event in toolEvents {
            group[event] = [
                [
                    "matcher": "*",
                    "hooks": [handler(sessionID: sessionID, event: event, crowPath: crowPath)],
                ] as [String: Any]
            ]
        }
        return group
    }

    // MARK: - HookConfigWriter conformance

    /// Write `<worktreePath>/.agents/hooks.json`, replacing only Crow's `"crow"`
    /// group and preserving every other named group. Git-excludes the file.
    public func writeHookConfig(
        worktreePath: String,
        sessionID: UUID,
        crowPath: String
    ) throws {
        let agentsDir = (worktreePath as NSString).appendingPathComponent(".agents")
        let hooksPath = (agentsDir as NSString).appendingPathComponent("hooks.json")

        // If the repo *tracks* `.agents/hooks.json`, refuse to write into it —
        // `.git/info/exclude` has no effect on tracked files, so an unattended
        // `git add -A` would commit Crow's absolute crow-path + dead session UUID
        // into the shared repo. Better to lose state detection for this one
        // worktree than poison the repo. Checked unconditionally so a
        // tracked-but-`rm`'d file is still caught.
        if Self.isGitTracked(worktreePath: worktreePath, relativePath: ".agents/hooks.json") {
            NSLog("[AntigravityHookConfigWriter] %@/.agents/hooks.json is git-tracked; not writing Crow's session hooks into a committed file. Gitignore/untrack it to enable hook-based state detection for this worktree.", worktreePath)
            return
        }

        try FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)

        // If the file EXISTS but doesn't parse (torn write, hand-edit), bail
        // rather than start from `[:]` and drop the user's other groups.
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: hooksPath) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("[AntigravityHookConfigWriter] %@ exists but is unparseable; leaving it untouched (would otherwise drop the user's own hook groups)", hooksPath)
                return
            }
            root = parsed
        }

        // Own only the `"crow"` group; every other named group is preserved.
        root[Self.groupKey] = Self.crowGroup(sessionID: sessionID, crowPath: crowPath)

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // Atomic (temp + rename): a crash mid-write would otherwise leave a
        // truncated file the unparseable-guard then refuses to touch, silently
        // disabling this worktree's hook-based state detection forever.
        try data.write(to: URL(fileURLWithPath: hooksPath), options: [.atomic])

        // Keep the session-specific config out of commits. One-way by design: the
        // pattern is a repo-level ignore shared by every worktree, so
        // `removeHookConfig` must NOT pull it back out.
        Self.ensureGitExcluded(worktreePath: worktreePath, pattern: ".agents/hooks.json")
    }

    /// Remove Crow's `"crow"` group from a worktree's `.agents/hooks.json`,
    /// preserving other groups. Deletes the file when nothing else remains.
    public func removeHookConfig(worktreePath: String) {
        let hooksPath = (worktreePath as NSString)
            .appendingPathComponent(".agents/hooks.json")
        Self.stripCrowGroup(at: hooksPath)
    }

    // MARK: - Global-config migration

    /// Strip Crow's `"crow"` group from the **global** `<geminiConfigHome>/hooks.json`
    /// (typically `~/.gemini/config`). Per-worktree configs are the authority;
    /// because Antigravity may merge global + workspace and run both, a surviving
    /// global Crow group would double-fire every event. Only Crow's group is
    /// removed — a user's other groups survive.
    public static func removeManagedGlobalConfig(geminiConfigHome: String) {
        let hooksPath = (geminiConfigHome as NSString).appendingPathComponent("hooks.json")
        stripCrowGroup(at: hooksPath)
    }

    // MARK: - Group-level helper

    /// Remove the `"crow"` group from `hooksPath`, preserving user groups; delete
    /// the file when nothing else remains. No-op when the file is absent,
    /// unparseable, or already Crow-free.
    private static func stripCrowGroup(at hooksPath: String) {
        guard let data = FileManager.default.contents(atPath: hooksPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root[groupKey] != nil else {
            return
        }
        root.removeValue(forKey: groupKey)

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

    // MARK: - Git-tracked probe (mirrors CursorHookConfigWriter)

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

    // MARK: - Git exclude (mirrors CursorHookConfigWriter)

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
