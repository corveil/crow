import Foundation
import CrowCore

/// Writes Muse Code's hook configuration into a worktree's `.muse/hooks.json`.
/// Conforms to `HookConfigWriter` so the engine can treat the configuration
/// step generically; the concrete event list and file format stay local to
/// CrowMuse.
///
/// **Why a per-worktree, per-session file.** Muse discovers project hooks
/// from `<project-root>/.muse/hooks.json` (official extending docs,
/// 2026-08-14). Lifecycle events are Claude-named (`SessionStart`,
/// `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`,
/// `Stop`, plus Muse-only `PreLLMCall` / `PostLLMCall` / compact / subagent
/// events). Crow bakes the session UUID into the command and the server
/// resolves the session **by UUID** — the same good tier as Claude/Cursor/Grok.
///
/// **Schema is a needs-eval pin.** Muse's hook *event names* are documented;
/// the on-disk JSON shape is not (no `muse --help` / `muse hooks validate`
/// was available — the installer is Meta-auth-gated). Crow writes a
/// Claude-compatible `{ "hooks": { "<Event>": [ { "hooks": [ { "type":
/// "command", "command": "…" } ] } ] } }` document because (a) the event
/// names match Claude's verbatim and (b) Muse already Claude-compat-loads
/// `CLAUDE.md` / `.claude/skills`. If a real binary rejects that shape, the
/// write is the re-check target — not a silent capability claim. User and
/// project hooks also require `muse hooks trust <key>` before they run;
/// `--trust-workspace` *loads* them. Whether load implies run is
/// **needs-eval** — state detection may stay dark until that is confirmed.
///
/// **`PreToolUse` is deliberately not registered.** Muse lists it as a
/// lifecycle event, but its stdout contract is unverified. Antigravity's
/// `PreToolUse` demands a strict verdict and a mis-shaped reply denies every
/// tool call; Crow stays off that gate until a real binary confirms an
/// observational no-op is safe. Tool activity is detected from `PostToolUse`.
///
/// `.muse/hooks.json` is the *project's* hook file (not a Crow-owned sidecar
/// in a directory of `*.json` the way Grok works). Write/remove therefore
/// follow Cursor's protections: a git-tracked file is left untouched, an
/// existing unparseable file is bailed on, and Crow only writes when the
/// file is missing or already Crow-owned (every command contains
/// `hook-event --session`). An untracked write is git-excluded.
public struct MuseHookConfigWriter: HookConfigWriter {

    /// Events Crow registers. Subset of the documented Muse lifecycle
    /// (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`,
    /// `PostToolUse`, `PreLLMCall`, `PostLLMCall`, `PreCompact`, `PostCompact`,
    /// `SubagentStart`, `SubagentStop`, `Stop`) — only the ones
    /// `MuseSignalSource` maps onto Crow's state machine. `PreToolUse` is
    /// excluded (see type doc).
    static let allEvents = [
        "SessionStart", "UserPromptSubmit",
        "PostToolUse", "PermissionRequest", "Stop",
    ]

    /// Muse's hook runtime async-delivery support is unverified, so
    /// everything is registered synchronously. Declaring `async` on an
    /// unknown schema risks a parse failure (Antigravity has no `async`
    /// field and would reject one).
    private static let asyncEvents: Set<String> = []

    public init() {}

    // MARK: - Generate Hook Configuration

    /// Build the Muse hooks document (`{ "hooks": { … } }`) for a session.
    /// Each event invokes `<crow> hook-event --session <UUID> --event <Name>`.
    static func generateDocument(sessionID: UUID, crowPath: String) -> [String: Any] {
        let sid = sessionID.uuidString
        var hooks: [String: Any] = [:]

        for event in allEvents {
            let command = "\(ShellLaunchArgs.shellQuote(crowPath)) hook-event --session \(sid) --event \(event)"
            var hookEntry: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 5,
            ]
            if asyncEvents.contains(event) {
                hookEntry["async"] = true
            }
            hooks[event] = [
                ["hooks": [hookEntry]] as [String: Any]
            ]
        }

        return ["hooks": hooks]
    }

    // MARK: - HookConfigWriter Conformance

    /// Write `<worktreePath>/.muse/hooks.json` with the session UUID baked
    /// in. See the type doc for the skip conditions.
    public func writeHookConfig(
        worktreePath: String,
        sessionID: UUID,
        crowPath: String
    ) throws {
        let museDir = Self.museDir(worktreePath)
        let filePath = (museDir as NSString).appendingPathComponent(Self.fileName)
        let relativePath = ".muse/\(Self.fileName)"

        if Self.isGitTracked(worktreePath: worktreePath, relativePath: relativePath) {
            CrowLog.info("[MuseHookConfigWriter] \(worktreePath)/\(relativePath) is git-tracked; not writing Crow's session hooks into a committed file. Gitignore/untrack it to enable hook-based state detection for this worktree.")
            return
        }

        if let existing = FileManager.default.contents(atPath: filePath) {
            guard let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
                  Self.isCrowOwned(parsed) else {
                CrowLog.info("[MuseHookConfigWriter] \(filePath) exists and is not Crow-owned (or is unparseable); leaving it untouched.")
                return
            }
        }

        try FileManager.default.createDirectory(atPath: museDir, withIntermediateDirectories: true)

        let document = Self.generateDocument(sessionID: sessionID, crowPath: crowPath)
        let data = try JSONSerialization.data(
            withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: filePath), options: [.atomic])
        Self.ensureGitExcluded(worktreePath: worktreePath, pattern: relativePath)
    }

    /// Remove Crow's `.muse/hooks.json` when it is Crow-owned. Leaves a
    /// user's own file untouched. Prunes `.muse/` when left empty.
    public func removeHookConfig(worktreePath: String) {
        let museDir = Self.museDir(worktreePath)
        let filePath = (museDir as NSString).appendingPathComponent(Self.fileName)
        if let data = FileManager.default.contents(atPath: filePath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           Self.isCrowOwned(parsed) {
            try? FileManager.default.removeItem(atPath: filePath)
        }
        Self.removeIfEmpty(museDir)
    }

    // MARK: - Crow-owned probe

    /// A file is Crow-owned when every registered event's command contains
    /// `hook-event --session`. A user's own hooks.json will not.
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

    // MARK: - Paths

    static let fileName = "hooks.json"

    private static func museDir(_ worktree: String) -> String {
        (worktree as NSString).appendingPathComponent(".muse")
    }

    private static func removeIfEmpty(_ dir: String) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir), contents.isEmpty else { return }
        try? fm.removeItem(atPath: dir)
    }

    // MARK: - Git-tracked probe (mirrors CursorHookConfigWriter / Antigravity)

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
