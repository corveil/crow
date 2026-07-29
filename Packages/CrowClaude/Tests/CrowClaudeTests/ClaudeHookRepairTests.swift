import Foundation
import Testing
import CrowCore
@testable import CrowClaude

/// #897: an old dev build baked `.build/{arch}/debug/crow` into every hook
/// command it wrote. That worktree was later reaped and its session deleted, so
/// the `settings.local.json` it left behind in a long-lived main clone failed
/// every hook event forever — noisy, and it silently dropped all telemetry for
/// sessions run there. `ClaudeHookRepair` is the only code that mutates a
/// settings file Crow did not itself just write, so these tests pin down what
/// it will and (mostly) will not touch.
@Suite("ClaudeHookRepair.parseCrowHookCommand")
struct ClaudeHookRepairParseTests {
    private let session = UUID(uuidString: "2BEF7A0D-743B-47A3-819A-C39C180F6977")!

    @Test func acceptsTheQuotedFormWeWriteToday() throws {
        let parsed = try #require(ClaudeHookRepair.parseCrowHookCommand(
            "'/Users/x/Dev/.claude/bin/crow' hook-event --session \(session.uuidString) --event Stop"))
        #expect(parsed.binary == "/Users/x/Dev/.claude/bin/crow")
        #expect(parsed.sessionID == session)
        #expect(parsed.event == "Stop")
    }

    /// Every file already on disk predates the quoting, so the parser must
    /// still recognize the legacy shape — that is the whole point.
    @Test func acceptsTheLegacyUnquotedForm() throws {
        let parsed = try #require(ClaudeHookRepair.parseCrowHookCommand(
            "/Users/x/Dev/crow-136/.build/arm64-apple-macosx/debug/crow"
            + " hook-event --session \(session.uuidString) --event PostToolUse"))
        #expect(parsed.binary.hasSuffix("/.build/arm64-apple-macosx/debug/crow"))
        #expect(parsed.event == "PostToolUse")
    }

    /// An unquoted path with a space is itself broken (the shell splits it) and
    /// is exactly a case worth repairing, so it must parse rather than be
    /// dismissed as "not ours".
    @Test func acceptsAnUnquotedPathContainingSpaces() throws {
        let parsed = try #require(ClaudeHookRepair.parseCrowHookCommand(
            "/Users/x/My Dev/.claude/bin/crow hook-event --session \(session.uuidString) --event Stop"))
        #expect(parsed.binary == "/Users/x/My Dev/.claude/bin/crow")
    }

    @Test func acceptsTheOptionalAgentFlag() throws {
        let parsed = try #require(ClaudeHookRepair.parseCrowHookCommand(
            "/bin/crow hook-event --session \(session.uuidString) --agent claude-code --event Stop"))
        #expect(parsed.event == "Stop")
    }

    @Test(arguments: [
        // A user hook that merely *wraps* our command is theirs, not ours.
        "/bin/crow hook-event --session 2BEF7A0D-743B-47A3-819A-C39C180F6977 --event Stop | tee /tmp/log",
        "/bin/crow hook-event --session 2BEF7A0D-743B-47A3-819A-C39C180F6977 --event Stop; rm -rf /",
        "echo hi && /bin/crow hook-event --session 2BEF7A0D-743B-47A3-819A-C39C180F6977 --event Stop",
        // Crow always writes an absolute path.
        "crow hook-event --session 2BEF7A0D-743B-47A3-819A-C39C180F6977 --event Stop",
        // Unknown flags, malformed uuid, unmanaged event name.
        "/bin/crow hook-event --session 2BEF7A0D-743B-47A3-819A-C39C180F6977 --event Stop --extra x",
        "/bin/crow hook-event --session not-a-uuid --event Stop",
        "/bin/crow hook-event --session 2BEF7A0D-743B-47A3-819A-C39C180F6977 --event MadeUpEvent",
        // Not a hook-event invocation at all.
        "/bin/crow list-sessions",
        "npm run lint",
    ])
    func rejectsAnythingThatIsNotExactlyOurShape(command: String) {
        #expect(ClaudeHookRepair.parseCrowHookCommand(command) == nil, "should not claim: \(command)")
    }
}

@Suite("ClaudeHookRepair.sweep")
struct ClaudeHookRepairSweepTests {
    private let deadSession = UUID(uuidString: "2BEF7A0D-743B-47A3-819A-C39C180F6977")!
    private let deadBinary = "/Users/x/Dev/crow-136-session-analytics-otel/.build/arm64-apple-macosx/debug/crow"

    // MARK: - Fixtures

    /// A dev root with a real, executable `crow` at the stable symlink path.
    private func makeDevRoot() throws -> (root: URL, crowPath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-hookrepair-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent(".claude/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let crow = binDir.appendingPathComponent("crow")
        try Data("#!/bin/sh\n".utf8).write(to: crow)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crow.path)
        return (root, crow.path)
    }

    @discardableResult
    private func makeDir(_ root: URL, _ components: String) throws -> URL {
        let url = root.appendingPathComponent(components)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The exact shape the old writer emitted: 17 event keys, one group each,
    /// one entry each.
    private func staleHookBlock(binary: String, session: UUID) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in ClaudeHookConfigWriter.allEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "\(binary) hook-event --session \(session.uuidString) --event \(event)",
                    "timeout": 5,
                ] as [String: Any]]
            ] as [String: Any]]
        }
        return hooks
    }

    private func writeSettings(_ settings: [String: Any], into dir: URL) throws {
        let claudeDir = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeDir.appendingPathComponent("settings.local.json"))
    }

    private func settingsPath(_ dir: URL) -> String {
        dir.appendingPathComponent(".claude/settings.local.json").path
    }

    /// The sweep standardizes every path it reports, and `LaunchScaffold` does
    /// the same to the worktree paths it snapshots — so tests must compare
    /// against standardized paths too. On macOS the temp dir is `/var/...`,
    /// a symlink to `/private/var/...`.
    private func std(_ url: URL) -> String { (url.path as NSString).standardizingPath }

    private func readSettings(_ dir: URL) throws -> [String: Any] {
        let data = try #require(FileManager.default.contents(atPath: settingsPath(dir)))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(in settings: [String: Any], event: String) throws -> [String] {
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let groups = try #require(hooks[event] as? [[String: Any]])
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Repair

    @Test func repairsAStaleBlockInPlaceWhenTheDirectoryIsALiveWorktree() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try makeDir(root, "RadiusMethod/crow-900-thing")
        let liveSession = UUID()

        try writeSettings([
            "hooks": staleHookBlock(binary: deadBinary, session: deadSession),
            "permissions": ["allow": ["Bash(git status)"]],
            "env": ["USER_VAR": "keep-me"],
        ], into: worktree)

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [liveSession],
            sessionByWorktreePath: [std(worktree): liveSession],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.repaired == [std(worktree)])
        #expect(summary.stripped.isEmpty)

        let updated = try readSettings(worktree)
        let hooks = try #require(updated["hooks"] as? [String: Any])
        // Every command now names the live session and the good binary…
        for event in ClaudeHookConfigWriter.allEvents {
            let commands = try commands(in: updated, event: event)
            #expect(commands == [ClaudeHookConfigWriter.hookCommand(
                crowPath: crowPath, sessionID: liveSession, event: event)])
        }
        // …with no keys added or removed, and unrelated settings preserved.
        #expect(Set(hooks.keys) == Set(ClaudeHookConfigWriter.allEvents))
        #expect(updated["permissions"] != nil)
        #expect((updated["env"] as? [String: Any])?["USER_VAR"] as? String == "keep-me")
    }

    /// A file that only ever had a subset of the events must not be expanded to
    /// all 17 — that would silently broaden Crow's footprint.
    @Test func repairDoesNotAddEventKeysTheFileNeverHad() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try makeDir(root, "ws/repo-1")
        let liveSession = UUID()

        var subset = staleHookBlock(binary: deadBinary, session: deadSession)
        for event in ClaudeHookConfigWriter.allEvents where event != "Stop" {
            subset.removeValue(forKey: event)
        }
        try writeSettings(["hooks": subset], into: worktree)

        _ = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [liveSession],
            sessionByWorktreePath: [std(worktree): liveSession],
            managerSessionID: AppState.managerSessionID)

        let hooks = try #require(try readSettings(worktree)["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["Stop"])
    }

    /// The Manager's block lives at `{devRoot}/.claude/settings.local.json` and
    /// its session has no worktree row, so a path lookup would find nothing and
    /// strip it — and nothing rewrites it on a warm daemon restart.
    @Test func managerBlockAtDevRootIsRepairedNotStripped() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSettings(
            ["hooks": staleHookBlock(binary: deadBinary, session: AppState.managerSessionID)],
            into: root)

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [],                      // Manager not in the snapshot
            sessionByWorktreePath: [:],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.repaired == [std(root)])
        let commands = try commands(in: try readSettings(root), event: "Stop")
        #expect(commands == [ClaudeHookConfigWriter.hookCommand(
            crowPath: crowPath, sessionID: AppState.managerSessionID, event: "Stop")])
    }

    @Test func repairPreservesOwnerOnlyPermissions() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try makeDir(root, "ws/repo-1")
        let liveSession = UUID()

        try writeSettings([
            "hooks": staleHookBlock(binary: deadBinary, session: deadSession),
            // The env block can carry a resolved gateway bearer token, which is
            // why writeGatewayEnv chmods this file 0600.
            "env": ["ANTHROPIC_CUSTOM_HEADERS": "X-Api-Key: secret"],
        ], into: worktree)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: settingsPath(worktree))

        _ = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [liveSession],
            sessionByWorktreePath: [std(worktree): liveSession],
            managerSessionID: AppState.managerSessionID)

        let attrs = try FileManager.default.attributesOfItem(atPath: settingsPath(worktree))
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    // MARK: - Strip

    /// The reported case, end to end: a long-lived main clone whose session is
    /// gone. The file held nothing but the stale block, so it goes away.
    @Test func deletesTheFileWhenNothingButStaleCrowHooksRemain() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainClone = try makeDir(root, "RadiusMethod/corveil")

        try writeSettings(
            ["hooks": staleHookBlock(binary: deadBinary, session: deadSession)], into: mainClone)

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.stripped == [std(mainClone)])
        #expect(!FileManager.default.fileExists(atPath: settingsPath(mainClone)))
    }

    /// Stripping must be surgical. `removeHookConfig` drops all 17 event keys
    /// wholesale, which would take a user's own `Stop` hook with it.
    @Test func stripKeepsUserHooksSharingAManagedEventName() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainClone = try makeDir(root, "RadiusMethod/corveil")

        var hooks = staleHookBlock(binary: deadBinary, session: deadSession)
        // A hand-authored entry alongside ours, under the same event key.
        hooks["Stop"] = [
            (hooks["Stop"] as! [[String: Any]])[0],
            ["hooks": [["type": "command", "command": "make lint"] as [String: Any]]] as [String: Any],
        ]
        try writeSettings(["hooks": hooks, "permissions": ["allow": ["Bash"]]], into: mainClone)

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.stripped == [std(mainClone)])
        let updated = try readSettings(mainClone)
        // Our 16 other event keys are gone; the user's Stop entry survives alone.
        let remaining = try #require(updated["hooks"] as? [String: Any])
        #expect(Set(remaining.keys) == ["Stop"])
        #expect(try commands(in: updated, event: "Stop") == ["make lint"])
        #expect(updated["permissions"] != nil)
    }

    /// With no resolvable crow binary there is nothing to repair *to*, but
    /// leaving dangling commands in place is worse than removing them.
    @Test func stripsWhenNoCrowBinaryCanBeResolved() throws {
        let (root, _) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try makeDir(root, "ws/repo-1")
        let liveSession = UUID()

        try writeSettings(
            ["hooks": staleHookBlock(binary: deadBinary, session: deadSession)], into: worktree)

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: nil,
            liveSessionIDs: [liveSession],
            sessionByWorktreePath: [std(worktree): liveSession],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.stripped == [std(worktree)])
    }

    // MARK: - Leave alone

    @Test func leavesAHealthyFileByteIdenticalAndUnwritten() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try makeDir(root, "ws/repo-1")
        let liveSession = UUID()

        try writeSettings(
            ["hooks": staleHookBlock(binary: crowPath, session: liveSession)], into: worktree)
        let before = try #require(FileManager.default.contents(atPath: settingsPath(worktree)))
        let mtimeBefore = try #require(
            FileManager.default.attributesOfItem(atPath: settingsPath(worktree))[.modificationDate] as? Date)

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [liveSession],
            sessionByWorktreePath: [std(worktree): liveSession],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.scanned == 1)
        #expect(summary.healthy == 1)
        #expect(summary.repaired.isEmpty && summary.stripped.isEmpty)
        #expect(try #require(FileManager.default.contents(atPath: settingsPath(worktree))) == before)
        let mtimeAfter = try #require(
            FileManager.default.attributesOfItem(atPath: settingsPath(worktree))[.modificationDate] as? Date)
        #expect(mtimeAfter == mtimeBefore)
    }

    @Test func ignoresFilesWithNoCrowManagedHooks() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try makeDir(root, "ws/repo-1")

        let userOnly: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "make lint"] as [String: Any]]] as [String: Any]],
                "MyCustomEvent": [["hooks": [["type": "command", "command": "echo hi"] as [String: Any]]] as [String: Any]],
            ],
        ]
        try writeSettings(userOnly, into: worktree)
        let before = try #require(FileManager.default.contents(atPath: settingsPath(worktree)))

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.scanned == 0)
        #expect(try #require(FileManager.default.contents(atPath: settingsPath(worktree))) == before)
    }

    // MARK: - Traversal

    @Test func skipsHiddenExcludedDeeperAndSymlinkedDirectories() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale: [String: Any] = ["hooks": staleHookBlock(binary: deadBinary, session: deadSession)]

        // Depth 3 — inside a build tree we must never descend into.
        let tooDeep = try makeDir(root, "ws/repo/.build/checkouts/dep")
        try writeSettings(stale, into: tooDeep)
        // An excluded directory name at depth 1.
        let excluded = try makeDir(root, "node_modules/pkg")
        try writeSettings(stale, into: excluded)
        // A dotted directory at depth 1.
        let hidden = try makeDir(root, ".cache/thing")
        try writeSettings(stale, into: hidden)

        // A workspace symlinked to somewhere outside the dev root.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-hookrepair-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try writeSettings(stale, into: try makeDir(outside, "repo"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("linked-ws").path,
            withDestinationPath: outside.path)

        // The one directory that SHOULD be visited, so the test can't pass by
        // the sweep doing nothing at all.
        let real = try makeDir(root, "ws/repo-real")
        try writeSettings(stale, into: real)

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:],
            managerSessionID: AppState.managerSessionID,
            excludeDirs: ["node_modules"])

        #expect(summary.scanned == 1)
        #expect(summary.stripped == [std(real)])
        for untouched in [tooDeep, excluded, hidden, outside.appendingPathComponent("repo")] {
            #expect(FileManager.default.fileExists(atPath: settingsPath(untouched)),
                    "should not have been swept: \(untouched.path)")
        }
    }

    @Test func leavesUnparseableFilesAlone() throws {
        let (root, crowPath) = try makeDevRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try makeDir(root, "ws/repo-1")
        let claudeDir = worktree.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: claudeDir.appendingPathComponent("settings.local.json"))

        let summary = ClaudeHookRepair.sweep(
            devRoot: root.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:],
            managerSessionID: AppState.managerSessionID)

        #expect(summary.skipped == [std(worktree)])
        #expect(try String(contentsOfFile: settingsPath(worktree), encoding: .utf8) == "{ not json")
    }
}

/// #915 — a linked worktree's `.git` is a file pointing at the main clone, and
/// project-root resolution follows it, so the main clone's
/// `.claude/settings.local.json` is loaded *in addition to* the worktree's own.
/// One block in a main clone therefore reaches every session on the repo.
///
/// These use real `git init` + `git worktree add` rather than fabricated `.git`
/// files: the resolution being compensated for is git's own, so a hand-made
/// fixture could agree with the code while both disagree with git.
@Suite("ClaudeHookRepair.reconcileMainClone")
struct ClaudeHookRepairMainCloneTests {
    private let deadSession = UUID(uuidString: "2BEF7A0D-743B-47A3-819A-C39C180F6977")!
    private let deadBinary = "/Users/x/Dev/crow-136-session-analytics-otel/.build/arm64-apple-macosx/debug/crow"

    private func std(_ url: URL) -> String { (url.path as NSString).standardizingPath }
    private func std(_ path: String) -> String { (path as NSString).standardizingPath }

    @discardableResult
    private func git(_ args: [String], cwd: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: out, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }

    /// A real main clone with one commit, plus one linked worktree beside it —
    /// the `{devRoot}/{workspace}/{repo}` + `{repo}-{n}-{slug}` sibling layout
    /// Crow uses.
    private func makeRepoWithWorktree() throws -> (root: URL, mainClone: URL, worktree: URL, crowPath: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-mainclone-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent(".claude/bin")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let crow = binDir.appendingPathComponent("crow")
        try Data("#!/bin/sh\n".utf8).write(to: crow)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: crow.path)

        let mainClone = root.appendingPathComponent("ws/repo")
        try FileManager.default.createDirectory(at: mainClone, withIntermediateDirectories: true)
        try git(["init", "--initial-branch=main", mainClone.path])
        try git(["-C", mainClone.path, "config", "user.email", "t@example.com"])
        try git(["-C", mainClone.path, "config", "user.name", "T"])
        try Data("x".utf8).write(to: mainClone.appendingPathComponent("README"))
        try git(["-C", mainClone.path, "add", "README"])
        try git(["-C", mainClone.path, "commit", "-m", "init"])

        // Sibling, not child — the layout that makes `/x/repo` a string prefix
        // of `/x/repo-1-slug` without being a parent of it.
        let worktree = root.appendingPathComponent("ws/repo-1-slug")
        try git(["-C", mainClone.path, "worktree", "add", worktree.path, "-b", "feature/x"])

        return (root, mainClone, worktree, crow.path)
    }

    private func staleHookBlock(binary: String, session: UUID) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in ClaudeHookConfigWriter.allEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "\(binary) hook-event --session \(session.uuidString) --event \(event)",
                    "timeout": 5,
                ] as [String: Any]]
            ] as [String: Any]]
        }
        return hooks
    }

    private func writeSettings(_ settings: [String: Any], into dir: URL) throws {
        let claudeDir = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeDir.appendingPathComponent("settings.local.json"))
    }

    private func settingsPath(_ dir: URL) -> String {
        dir.appendingPathComponent(".claude/settings.local.json").path
    }

    private func commands(in dir: URL, event: String) throws -> [String] {
        let data = try #require(FileManager.default.contents(atPath: settingsPath(dir)))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let groups = try #require(hooks[event] as? [[String: Any]])
        return groups.flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Resolution

    @Test("resolves the main clone from a real linked worktree")
    func resolvesMainCloneFromWorktree() throws {
        let (root, mainClone, worktree, _) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ClaudeHookRepair.resolveMainClone(worktreePath: worktree.path) == std(mainClone))
        // Agrees with git's own answer, which is what the agent harness follows.
        let commonDir = try git(["-C", worktree.path, "rev-parse", "--path-format=absolute",
                                 "--git-common-dir"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(std((commonDir as NSString).deletingLastPathComponent) == std(mainClone))
    }

    @Test("a main clone has no separate main clone")
    func mainCloneResolvesToNil() throws {
        let (root, mainClone, _, _) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ClaudeHookRepair.resolveMainClone(worktreePath: mainClone.path) == nil)
    }

    @Test("a plain directory is not a worktree")
    func plainDirectoryIsNotAWorktree() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-notrepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ClaudeHookRepair.resolveMainClone(worktreePath: dir.path) == nil)
    }

    /// A `.git` file we can't confidently interpret must resolve to nothing.
    /// Guessing would aim the strip at an unrelated directory — and this code
    /// deletes hook entries.
    @Test("an unrecognizable gitdir pointer resolves to nothing")
    func malformedGitFileResolvesToNil() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-badgit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, contents) in [
            // No `commondir`, and not the `<main>/.git/worktrees/<name>` shape.
            ("odd-shape", "gitdir: \(root.path)/somewhere/else"),
            ("not-a-pointer", "just some text"),
            ("empty-pointer", "gitdir:"),
        ] {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: dir.appendingPathComponent(".git"))
            #expect(ClaudeHookRepair.resolveMainClone(worktreePath: dir.path) == nil,
                    "\(name) should not resolve")
        }
    }

    // MARK: - Reconciliation

    /// The reported case: the main clone's file holds *only* the stale block, so
    /// reconciliation removes the file outright and the repo's worktree sessions
    /// stop erroring.
    @Test("strips a stale block from a main clone no session owns")
    func stripsStaleBlockFromUnownedMainClone() throws {
        let (root, mainClone, worktree, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let liveSession = UUID()

        try writeSettings(
            ["hooks": staleHookBlock(binary: deadBinary, session: deadSession)], into: mainClone)

        let outcome = ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktree.path, crowPath: crowPath,
            liveSessionIDs: [liveSession],
            sessionByWorktreePath: [std(worktree): liveSession])

        #expect(outcome == .stripped(mainClone: std(mainClone)))
        #expect(!FileManager.default.fileExists(atPath: settingsPath(mainClone)))
    }

    /// The #915 case #900's sweep cannot see: the block is *healthy* by its
    /// per-directory test (good binary, live session) and is left alone there —
    /// yet it still fires in every worktree session of the repo.
    @Test("strips a live-but-foreign block from a main clone no session owns")
    func stripsHealthyForeignBlock() throws {
        let (root, mainClone, worktree, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktreeSession = UUID()
        let otherLiveSession = UUID()

        try writeSettings([
            "hooks": staleHookBlock(binary: crowPath, session: otherLiveSession),
            "permissions": ["allow": ["Bash(git status)"]],
        ], into: mainClone)

        let outcome = ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktree.path, crowPath: crowPath,
            liveSessionIDs: [worktreeSession, otherLiveSession],
            sessionByWorktreePath: [std(worktree): worktreeSession])

        #expect(outcome == .stripped(mainClone: std(mainClone)))
        // The user's own keys survive; only our entries go.
        let data = try #require(FileManager.default.contents(atPath: settingsPath(mainClone)))
        let settings = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(settings["hooks"] == nil)
        #expect(settings["permissions"] != nil)
    }

    /// A main clone can legitimately host a session (`crow add-worktree` for an
    /// `alwaysInclude` reference repo). Its block is repaired for that session
    /// rather than removed — the daemon's cwd-authoritative resolution is what
    /// keeps it from firing in the repo's *worktree* sessions.
    @Test("repairs a stale block for the session that owns the main clone")
    func repairsBlockOwnedByALiveSession() throws {
        let (root, mainClone, worktree, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainCloneSession = UUID()
        let worktreeSession = UUID()

        try writeSettings(
            ["hooks": staleHookBlock(binary: deadBinary, session: deadSession)], into: mainClone)

        let outcome = ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktree.path, crowPath: crowPath,
            liveSessionIDs: [mainCloneSession, worktreeSession],
            sessionByWorktreePath: [
                std(mainClone): mainCloneSession, std(worktree): worktreeSession,
            ])

        #expect(outcome == .repaired(mainClone: std(mainClone)))
        let stop = try commands(in: mainClone, event: "Stop")
        #expect(stop.count == 1)
        #expect(stop[0].contains(mainCloneSession.uuidString))
        #expect(!stop[0].contains("/.build/"))
    }

    @Test("leaves a correct, owned block untouched")
    func leavesHealthyOwnedBlockAlone() throws {
        let (root, mainClone, worktree, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainCloneSession = UUID()

        try writeSettings(
            ["hooks": staleHookBlock(binary: crowPath, session: mainCloneSession)], into: mainClone)
        let before = try #require(FileManager.default.contents(atPath: settingsPath(mainClone)))

        let outcome = ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktree.path, crowPath: crowPath,
            liveSessionIDs: [mainCloneSession],
            sessionByWorktreePath: [std(mainClone): mainCloneSession])

        #expect(outcome == .healthy)
        #expect(FileManager.default.contents(atPath: settingsPath(mainClone)) == before)
    }

    /// A row whose session is gone must not keep a block alive — otherwise a
    /// failed delete leaves the repo emitting hook errors indefinitely.
    @Test("a row for a dead session does not count as an owner")
    func deadOwnerIsNotAnOwner() throws {
        let (root, mainClone, worktree, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let ghost = UUID()

        try writeSettings(
            ["hooks": staleHookBlock(binary: crowPath, session: ghost)], into: mainClone)

        let outcome = ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktree.path, crowPath: crowPath,
            liveSessionIDs: [],  // ghost is not live
            sessionByWorktreePath: [std(mainClone): ghost])

        #expect(outcome == .stripped(mainClone: std(mainClone)))
    }

    @Test("a main clone with no Crow block is left alone")
    func noBlockIsANoOp() throws {
        let (root, mainClone, worktree, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSettings(["permissions": ["allow": ["Bash(git status)"]]], into: mainClone)

        let outcome = ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktree.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:])

        #expect(outcome == .noBlock)
        #expect(FileManager.default.fileExists(atPath: settingsPath(mainClone)))
    }

    /// A user's own hook that happens to share a managed event name is not ours
    /// to remove — the same boundary `stripCrowEntries` holds for the sweep.
    @Test("a user's own hook under a managed event name survives a strip")
    func userHookSurvivesStrip() throws {
        let (root, mainClone, worktree, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        var hooks = staleHookBlock(binary: deadBinary, session: deadSession)
        hooks["Stop"] = [
            [
                "hooks": [
                    ["type": "command",
                     "command": "\(deadBinary) hook-event --session \(deadSession.uuidString) --event Stop",
                     "timeout": 5] as [String: Any],
                    ["type": "command", "command": "say done", "timeout": 5] as [String: Any],
                ]
            ] as [String: Any]
        ]
        try writeSettings(["hooks": hooks], into: mainClone)

        let outcome = ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktree.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:])

        #expect(outcome == .stripped(mainClone: std(mainClone)))
        #expect(try commands(in: mainClone, event: "Stop") == ["say done"])
    }

    /// The reaper's entry point: it reconciles after `git worktree remove`, so
    /// the worktree that would have resolved the clone is already gone.
    @Test("reconciles a main clone directly, without a worktree to resolve it")
    func reconcilesDirectoryDirectly() throws {
        let (root, mainClone, _, crowPath) = try makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeSettings(
            ["hooks": staleHookBlock(binary: deadBinary, session: deadSession)], into: mainClone)

        let outcome = ClaudeHookRepair.reconcileHookBlock(
            inDirectory: mainClone.path, crowPath: crowPath,
            liveSessionIDs: [], sessionByWorktreePath: [:])

        #expect(outcome == .stripped(mainClone: std(mainClone)))
        #expect(!FileManager.default.fileExists(atPath: settingsPath(mainClone)))
    }
}
