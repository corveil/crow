import Foundation
import CrowCore

/// Repairs Crow-written Claude Code hook blocks that have gone stale on disk
/// (#897).
///
/// The failure this exists for: an old dev build baked its own
/// `.build/{arch}/debug/crow` path into every hook command it wrote. That
/// worktree was later reaped, the session it named was deleted, and nothing in
/// Crow ever revisits a `settings.local.json` once written — so the directory
/// kept emitting `No such file or directory` on every hook event, and every
/// session run there recorded no telemetry at all.
///
/// `ClaudeHookConfigWriter.resolveCrowBinary` stops *new* files from going
/// stale (commands now name the `{devRoot}/.claude/bin/crow` symlink, whose
/// target is re-pointed on every boot). This type cleans up the files written
/// before that, and any that go stale some other way.
///
/// The scan is deliberately **filesystem-driven, not state-driven**: the whole
/// point is that the broken directory's session is gone from `AppState`, which
/// is exactly why enumerating live worktrees would miss it.
public enum ClaudeHookRepair {

    // MARK: - Parsing

    /// A hook command recognized as one Crow wrote.
    public struct ParsedCrowHook: Equatable, Sendable {
        /// The crow binary path, already unquoted.
        public let binary: String
        public let sessionID: UUID
        public let event: String
    }

    /// Shell metacharacters that turn a command into something more than a
    /// plain invocation. A user hook that *wraps* `crow hook-event` in a
    /// pipeline or chain is theirs, not ours — we must not rewrite it.
    private static let disqualifyingCharacters: Set<Character> = [";", "|", "&", ">", "<", "`", "$", "(", ")", "\n"]

    /// Parse `<abs-path> hook-event --session <uuid> [--agent <kind>] --event <Name>`,
    /// as emitted by `ClaudeHookConfigWriter.hookCommand`. Returns `nil` for
    /// anything that isn't exactly that shape.
    ///
    /// This predicate is the entire safety boundary for the sweep — everything
    /// it accepts may be rewritten or deleted — so it is intentionally strict
    /// and rejects on any surprise.
    ///
    /// Not a single anchored regex: `\S+` for the binary would fail on the
    /// legacy *unquoted* path-containing-a-space form, which is itself broken
    /// and is precisely a case worth repairing. So the binary is taken as
    /// everything before the first ` hook-event ` instead.
    public static func parseCrowHookCommand(_ command: String) -> ParsedCrowHook? {
        let marker = " hook-event "
        guard let markerRange = command.range(of: marker) else { return nil }

        var binary = String(command[command.startIndex..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        // Reverse `ClaudeLaunchArgs.shellQuote`. Only a fully-wrapped value is
        // accepted; a partially quoted path is a shape we never wrote. Content
        // inside single quotes is inert to the shell, so it needs no further
        // scrutiny — but an *unquoted* segment (every pre-#897 file on disk) is
        // raw shell, so any metacharacter there means it isn't a plain
        // invocation and isn't ours.
        if binary.count >= 2, binary.hasPrefix("'"), binary.hasSuffix("'") {
            binary = String(binary.dropFirst().dropLast())
                .replacingOccurrences(of: "'\\''", with: "'")
        } else if binary.contains("'") || binary.contains("\"")
                    || binary.contains(where: disqualifyingCharacters.contains) {
            return nil
        }
        // Crow always writes an absolute path.
        guard binary.hasPrefix("/") else { return nil }

        let rest = String(command[markerRange.upperBound...])
        guard !rest.contains(where: disqualifyingCharacters.contains) else { return nil }
        let tokens = rest.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        var sessionID: UUID?
        var event: String?
        var index = 0
        while index < tokens.count {
            let flag = tokens[index]
            guard index + 1 < tokens.count else { return nil }
            let value = tokens[index + 1]
            switch flag {
            case "--session":
                guard sessionID == nil, let parsed = UUID(uuidString: value) else { return nil }
                sessionID = parsed
            case "--event":
                guard event == nil else { return nil }
                event = value
            case "--agent":
                break  // Optional; its value is not load-bearing for repair.
            default:
                return nil  // Any token we don't recognize means this isn't ours.
            }
            index += 2
        }

        guard let sessionID, let event, ClaudeHookConfigWriter.allEvents.contains(event) else { return nil }
        return ParsedCrowHook(binary: binary, sessionID: sessionID, event: event)
    }

    // MARK: - Sweep

    /// What one sweep did, for the boot log.
    public struct Summary: Equatable, Sendable {
        /// Directories that held a Crow-managed hook block.
        public var scanned: Int = 0
        /// Of those, the ones already correct — not written to at all.
        public var healthy: Int = 0
        /// Directories whose commands were rewritten to a live session + good binary.
        public var repaired: [String] = []
        /// Directories whose Crow-managed entries were removed (no live session).
        public var stripped: [String] = []
        /// Directories skipped because the file was unparseable or unwritable.
        public var skipped: [String] = []

        public init() {}

        /// One-line form for `crowd`'s boot log.
        public var logLine: String {
            var line = "scanned \(scanned) hook block(s), \(healthy) healthy"
            if !repaired.isEmpty { line += ", repaired \(repaired.count): \(repaired.joined(separator: ", "))" }
            if !stripped.isEmpty { line += ", stripped \(stripped.count): \(stripped.joined(separator: ", "))" }
            if !skipped.isEmpty { line += ", skipped \(skipped.count): \(skipped.joined(separator: ", "))" }
            return line
        }
    }

    /// Scan under `devRoot` and repair (or remove) stale Crow hook blocks.
    ///
    /// - Parameters:
    ///   - crowPath: the binary to write into repaired commands, normally
    ///     `ClaudeHookConfigWriter.resolveCrowBinary(devRoot:)`. When `nil`
    ///     nothing can be repaired, so stale blocks are stripped instead —
    ///     which still stops the hook errors and is better than leaving
    ///     dangling commands in place.
    ///   - liveSessionIDs / sessionByWorktreePath: a value snapshot of
    ///     `AppState`, so this stays off the MainActor. Worktree paths must be
    ///     `standardizingPath`-normalized.
    ///   - managerSessionID: `AppState.managerSessionID`. The Manager's block
    ///     lives at `{devRoot}/.claude/settings.local.json` and its session has
    ///     no `SessionWorktree` row, so it is matched by this constant rather
    ///     than by path lookup — without that it would be stripped, and nothing
    ///     rewrites it on a warm daemon restart.
    ///
    /// Performs blocking file I/O; call from a detached task, never the
    /// MainActor (#892).
    public static func sweep(
        devRoot: String,
        crowPath: String?,
        liveSessionIDs: Set<UUID>,
        sessionByWorktreePath: [String: UUID],
        managerSessionID: UUID,
        excludeDirs: Set<String> = [],
        maxDirs: Int = 2000
    ) -> Summary {
        var summary = Summary()
        for dir in candidateDirectories(
            devRoot: devRoot, excludeDirs: excludeDirs, maxDirs: maxDirs
        ) {
            let desiredSession = (dir == (devRoot as NSString).standardizingPath)
                ? managerSessionID
                : sessionByWorktreePath[dir]
            repairDirectory(
                dir, crowPath: crowPath, liveSessionIDs: liveSessionIDs,
                desiredSession: desiredSession, into: &summary)
        }
        return summary
    }

    // MARK: - Traversal

    /// `devRoot` itself (the Manager) plus every directory two levels down —
    /// `{devRoot}/{workspace}/{repo-or-worktree}`, which covers work and job
    /// worktrees, main clones (the reported case), and review clones under
    /// `crow-reviews/`.
    ///
    /// Depth is capped at 2 on purpose: it matches the layout `Scaffolder`,
    /// `detectOrphanedWorktrees`, and `workspaceName(forWorktreePath:devRoot:)`
    /// already assume, and it means `.build`/`node_modules` (depth 3+) are
    /// never reached at all.
    static func candidateDirectories(
        devRoot: String, excludeDirs: Set<String>, maxDirs: Int
    ) -> [String] {
        let fm = FileManager.default
        let root = (devRoot as NSString).standardizingPath
        var candidates = [root]

        func children(of path: String) -> [String] {
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return [] }
            return entries.sorted().compactMap { name in
                // Dotted names cover `.claude`, `.git`, and every other dot dir.
                guard !name.hasPrefix("."), !excludeDirs.contains(name) else { return nil }
                let child = (path as NSString).appendingPathComponent(name)
                // `attributesOfItem` lstats — unlike `fileExists(isDirectory:)`,
                // which follows symlinks. A workspace symlinked outside devRoot
                // must not be walked.
                guard let attrs = try? fm.attributesOfItem(atPath: child),
                      (attrs[.type] as? FileAttributeType) == .typeDirectory else { return nil }
                return child
            }
        }

        outer: for workspace in children(of: root) {
            for candidate in children(of: workspace) {
                candidates.append(candidate)
                if candidates.count >= maxDirs {
                    CrowLog.info(
                        "[ClaudeHookRepair] hit the \(maxDirs)-directory cap under \(root)"
                        + " — stopping the scan early; later directories were not checked.")
                    break outer
                }
            }
        }
        return candidates
    }

    // MARK: - Main-clone reconciliation (#915)

    /// What `reconcileMainClone` did, for the launch log.
    public enum MainCloneOutcome: Equatable, Sendable {
        /// `worktreePath` is not a linked worktree (its `.git` is a directory),
        /// so there is no separate main clone to reconcile.
        case notAWorktree
        /// The main clone holds no Crow-managed hook block.
        case noBlock
        /// The block belongs to the session that owns that directory and is
        /// healthy — left untouched.
        case healthy
        /// Rewritten to the owning session and a good binary.
        case repaired(mainClone: String)
        /// Crow entries removed: nothing legitimately runs from that directory.
        case stripped(mainClone: String)
        /// Present but not safely actionable (unparseable or unwritable).
        case skipped(mainClone: String)
    }

    /// Reconcile the **main clone's** hook block before launching an agent in
    /// one of its worktrees (#915).
    ///
    /// A linked worktree's `.git` is a file pointing at the main clone, and
    /// project-root resolution follows it — so the main clone's
    /// `.claude/settings.local.json` is loaded *in addition to* the worktree's
    /// own, and both hook sets run. Crow writes the per-worktree file and treats
    /// it as the session's configuration; it is not. One stale block in a main
    /// clone breaks hooks and telemetry for **every** session on that repo, and
    /// one merely *foreign* block (naming a different live session) misattributes
    /// their events and fires each twice.
    ///
    /// `sweep` cannot cover this. It is boot-time only, walks devRoot at a fixed
    /// depth of 2 (so a clone living anywhere else is invisible), and — decisively
    /// — its health test is per-directory: a block naming a live session *is*
    /// healthy by that test, which is exactly the case that must still go.
    ///
    /// The decision, given the directory the block sits in:
    ///
    /// | Main clone is… | Action |
    /// |---|---|
    /// | this session's own worktree | leave (it is this session's own block) |
    /// | another live session's worktree | repair in place for that session |
    /// | no live session's worktree | strip Crow entries |
    ///
    /// Note "repair" keeps a legitimately-hosted block working: the daemon's
    /// cwd-authoritative `hook-event` resolution drops it when it fires inside a
    /// *worktree* session, and accepts it when it fires in the main clone itself.
    ///
    /// Performs blocking file I/O; call off the MainActor (#892).
    public static func reconcileMainClone(
        worktreePath: String,
        crowPath: String?,
        liveSessionIDs: Set<UUID>,
        sessionByWorktreePath: [String: UUID]
    ) -> MainCloneOutcome {
        guard let mainClone = resolveMainClone(worktreePath: worktreePath) else {
            return .notAWorktree
        }
        // A worktree whose main clone is itself (shouldn't happen, but a
        // hand-made `.git` file could say so) needs no reconciliation.
        let worktree = (worktreePath as NSString).standardizingPath
        guard mainClone != worktree else { return .notAWorktree }

        return reconcileHookBlock(
            inDirectory: mainClone, crowPath: crowPath,
            liveSessionIDs: liveSessionIDs, sessionByWorktreePath: sessionByWorktreePath)
    }

    /// `reconcileMainClone` for a directory already known to be the main clone.
    ///
    /// Split out for the retention reaper, which reconciles *after*
    /// `git worktree remove` has deleted the worktree — so `resolveMainClone`
    /// has no `.git` file left to read, but `WorktreeCleanupItem.repoPath`
    /// already names the clone directly.
    public static func reconcileHookBlock(
        inDirectory dir: String,
        crowPath: String?,
        liveSessionIDs: Set<UUID>,
        sessionByWorktreePath: [String: UUID]
    ) -> MainCloneOutcome {
        let dir = (dir as NSString).standardizingPath
        // The session that legitimately owns that directory, if any. Only a
        // *live* one counts — a row for a deleted session must not keep a block
        // alive.
        let owner = sessionByWorktreePath[dir].flatMap {
            liveSessionIDs.contains($0) ? $0 : nil
        }
        return reconcileDirectory(dir, owner: owner, crowPath: crowPath)
    }

    /// The main clone backing a linked worktree, or `nil` when `worktreePath`
    /// is not a linked worktree.
    ///
    /// Reads the gitdir chain directly rather than shelling out to
    /// `git rev-parse --git-common-dir`: it is the same resolution, but with no
    /// subprocess on the launch path, no dependency on `git` being found, and no
    /// async hop in a `nonisolated static` caller. It also mirrors what the agent
    /// harness itself does, which is the behavior we are compensating for.
    ///
    /// - `.git` a directory → this is a main clone (or a bare repo); no separate
    ///   main clone exists.
    /// - `.git` a file → `gitdir: <path>` names the worktree's private gitdir,
    ///   e.g. `<main>/.git/worktrees/<name>`. The shared dir is that gitdir's
    ///   `commondir` (git writes it, normally `../..`), and the main clone is its
    ///   parent.
    static func resolveMainClone(worktreePath: String) -> String? {
        let fm = FileManager.default
        let dotGit = (worktreePath as NSString).appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return nil }

        guard let raw = try? String(contentsOfFile: dotGit, encoding: .utf8) else { return nil }
        // A `.git` file is a single `gitdir: <path>` line. Anything else is not
        // a shape we understand, and guessing would be worse than doing nothing.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("gitdir:") else { return nil }
        let pointer = String(trimmed.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespaces)
        guard !pointer.isEmpty else { return nil }
        let gitDir = absolutePath(pointer, relativeTo: worktreePath)

        // `commondir` is authoritative when present; the `../..` derivation is
        // only a fallback for an oddly-shaped gitdir.
        let commonDirFile = (gitDir as NSString).appendingPathComponent("commondir")
        let commonDir: String
        if let contents = try? String(contentsOfFile: commonDirFile, encoding: .utf8) {
            let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            commonDir = absolutePath(value, relativeTo: gitDir)
        } else {
            // No `commondir` — only trust the `../..` derivation when the gitdir
            // has the shape git gives a linked worktree. Anything else and we do
            // not know where the shared dir is; guessing would point the strip at
            // an unrelated directory, so decline instead.
            let parent = (gitDir as NSString).deletingLastPathComponent
            guard (parent as NSString).lastPathComponent == "worktrees" else { return nil }
            commonDir = (parent as NSString).deletingLastPathComponent
        }

        // `commonDir` is the main clone's `.git`; its parent is the working tree.
        // Require that name: a shared dir called anything else means we did not
        // resolve what we think we did.
        guard (commonDir as NSString).lastPathComponent == ".git" else { return nil }
        let mainClone = (commonDir as NSString).deletingLastPathComponent
        guard !mainClone.isEmpty, mainClone != "/" else { return nil }
        return (mainClone as NSString).standardizingPath
    }

    /// Resolve `path` against `base` when it is relative, then normalize.
    private static func absolutePath(_ path: String, relativeTo base: String) -> String {
        let joined = path.hasPrefix("/")
            ? path
            : (base as NSString).appendingPathComponent(path)
        return (joined as NSString).standardizingPath
    }

    /// Apply the #915 decision to one directory's settings file.
    ///
    /// Distinct from `repairDirectory` in exactly one way, and it is the point of
    /// the issue: health here means "every entry names `owner`", not merely "the
    /// binary exists and the session is live". A block naming some *other* live
    /// session passes the latter and must still fail the former.
    private static func reconcileDirectory(
        _ dir: String, owner: UUID?, crowPath: String?
    ) -> MainCloneOutcome {
        let fm = FileManager.default
        let settingsPath = (dir as NSString).appendingPathComponent(".claude/settings.local.json")
        guard let data = fm.contents(atPath: settingsPath) else { return .noBlock }
        guard var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            // Same rule as `repairDirectory`: a file that exists but doesn't
            // parse is left strictly alone — we can't tell our entries from the
            // user's, and rewriting from `[:]` would drop every unrelated key.
            return (try? JSONSerialization.jsonObject(with: data)) == nil
                ? .skipped(mainClone: dir) : .noBlock
        }

        let parsed = parsedCrowHooks(in: hooks)
        guard !parsed.isEmpty else { return .noBlock }

        if let owner,
           parsed.allSatisfy({
               $0.sessionID == owner && fm.isExecutableFile(atPath: $0.binary)
           }) {
            return .healthy
        }

        let updatedHooks: [String: Any]
        let outcome: MainCloneOutcome
        if let owner, let crowPath {
            updatedHooks = rewriteCommands(in: hooks, crowPath: crowPath, sessionID: owner)
            outcome = .repaired(mainClone: dir)
        } else {
            // No live session owns this directory (or we have no good binary to
            // write): nothing here can fire correctly, so remove only what we
            // recognize as ours.
            updatedHooks = stripCrowEntries(from: hooks)
            outcome = .stripped(mainClone: dir)
        }

        if updatedHooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = updatedHooks
        }

        do {
            try writeSettings(settings, to: settingsPath)
        } catch {
            CrowLog.info(
                "[ClaudeHookRepair] failed to write \(settingsPath): \(error.localizedDescription)")
            return .skipped(mainClone: dir)
        }
        return outcome
    }

    /// Every Crow-managed hook command in a `hooks` dictionary.
    static func parsedCrowHooks(in hooks: [String: Any]) -> [ParsedCrowHook] {
        var parsed: [ParsedCrowHook] = []
        for event in ClaudeHookConfigWriter.allEvents {
            for group in (hooks[event] as? [[String: Any]] ?? []) {
                for entry in (group["hooks"] as? [[String: Any]] ?? []) {
                    if let command = entry["command"] as? String,
                       let hook = parseCrowHookCommand(command) {
                        parsed.append(hook)
                    }
                }
            }
        }
        return parsed
    }

    /// Write a settings dictionary back, deleting the file when nothing is left.
    ///
    /// NON-atomic on purpose: `writeGatewayEnv` chmods this file 0600 because its
    /// `env` block can carry a gateway bearer token, and an atomic write replaces
    /// the inode, resetting the mode to the umask default. Truncating in place
    /// preserves both.
    private static func writeSettings(_ settings: [String: Any], to path: String) throws {
        if settings.isEmpty {
            // Nothing of ours or the user's left — the file only ever held the
            // stale block (exactly the reported case).
            try FileManager.default.removeItem(atPath: path)
        } else {
            let out = try JSONSerialization.data(
                withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Per-directory repair

    private static func repairDirectory(
        _ dir: String,
        crowPath: String?,
        liveSessionIDs: Set<UUID>,
        desiredSession: UUID?,
        into summary: inout Summary
    ) {
        let fm = FileManager.default
        let settingsPath = (dir as NSString).appendingPathComponent(".claude/settings.local.json")
        guard let data = fm.contents(atPath: settingsPath) else { return }
        guard var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            // A file that exists but doesn't parse is left strictly alone: we
            // can't tell our entries from the user's, and rewriting from `[:]`
            // would drop every unrelated key.
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                summary.skipped.append(dir)
            }
            return
        }

        // Inventory first — decide before touching anything.
        let parsed = parsedCrowHooks(in: hooks)
        guard !parsed.isEmpty else { return }
        summary.scanned += 1

        let allHealthy = parsed.allSatisfy {
            fm.isExecutableFile(atPath: $0.binary) && liveSessionIDs.contains($0.sessionID)
        }
        if allHealthy {
            summary.healthy += 1
            return  // No write at all — mtime and contents untouched.
        }

        let updatedHooks: [String: Any]
        let action: String
        if let sessionID = desiredSession, let crowPath {
            updatedHooks = rewriteCommands(in: hooks, crowPath: crowPath, sessionID: sessionID)
            action = "repaired"
        } else {
            updatedHooks = stripCrowEntries(from: hooks)
            action = "stripped"
        }

        if updatedHooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = updatedHooks
        }

        do {
            try writeSettings(settings, to: settingsPath)
        } catch {
            CrowLog.info("[ClaudeHookRepair] failed to write \(settingsPath): \(error.localizedDescription)")
            summary.skipped.append(dir)
            return
        }

        if action == "repaired" {
            summary.repaired.append(dir)
        } else {
            summary.stripped.append(dir)
        }
    }

    /// Rewrite every Crow-managed command in place, keeping the file's existing
    /// shape: same event keys, same matcher groups, same `type`/`timeout`/`async`.
    ///
    /// Deliberately not `ClaudeHookConfigWriter.writeHookConfig`, which expands
    /// to all 17 events and replaces each event key's whole array — on a
    /// directory that only ever had a subset that silently re-broadens Crow's
    /// footprint and destroys user matcher groups. Taking the event name from
    /// the *key* rather than the parsed command also self-heals a key/command
    /// mismatch for free.
    private static func rewriteCommands(
        in hooks: [String: Any], crowPath: String, sessionID: UUID
    ) -> [String: Any] {
        var updated = hooks
        for event in ClaudeHookConfigWriter.allEvents {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            updated[event] = groups.map { group -> [String: Any] in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                var group = group
                group["hooks"] = entries.map { entry -> [String: Any] in
                    guard let command = entry["command"] as? String,
                          parseCrowHookCommand(command) != nil else { return entry }
                    var entry = entry
                    entry["command"] = ClaudeHookConfigWriter.hookCommand(
                        crowPath: crowPath, sessionID: sessionID, event: event)
                    return entry
                }
                return group
            }
        }
        return updated
    }

    /// Remove only the entries we recognize as ours, dropping groups and event
    /// keys that end up empty.
    ///
    /// Deliberately not `ClaudeHookConfigWriter.removeHookConfig`, which drops
    /// all 17 event keys wholesale — including a user's own hand-authored
    /// `Stop` or `PreToolUse` entry that merely shares an event name.
    /// `SessionService.writeManagerHookConfig` already documents refusing to
    /// run that against the dev root for the same reason.
    private static func stripCrowEntries(from hooks: [String: Any]) -> [String: Any] {
        var updated = hooks
        for event in ClaudeHookConfigWriter.allEvents {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let entries = group["hooks"] as? [[String: Any]] else { return group }
                let survivors = entries.filter { entry in
                    guard let command = entry["command"] as? String else { return true }
                    return parseCrowHookCommand(command) == nil
                }
                if survivors.isEmpty { return nil }
                var group = group
                group["hooks"] = survivors
                return group
            }
            if kept.isEmpty {
                updated.removeValue(forKey: event)
            } else {
                updated[event] = kept
            }
        }
        return updated
    }
}
