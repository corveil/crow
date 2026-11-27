import Foundation
import Testing
@testable import CrowClaude

/// CROW-1527: detecting `permissions.blockReadsOutsideWorkingDirectories` for a
/// Claude auto-mode launch. Every case uses a temp-dir home and cwd; the
/// operator's real `~/.claude/settings.json` is never read.
@Suite("ClaudeOutsideReadsBlock")
struct ClaudeOutsideReadsBlockTests {
    /// A throwaway home + cwd pair under the temp directory.
    struct Fixture {
        let root: URL
        var home: String { root.appendingPathComponent("home").path }
        var userClaudeDir: String { "\(home)/.claude" }
        var cwd: String { root.appendingPathComponent("worktree").path }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("crow-1527-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var userSettings: String { "\(home)/.claude/settings.json" }
        var projectSettings: String { "\(cwd)/.claude/settings.json" }
        var localSettings: String { "\(cwd)/.claude/settings.local.json" }

        func write(_ path: String, _ text: String) throws {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func check() -> ClaudeOutsideReadsBlock.Finding? {
            ClaudeOutsideReadsBlock.check(userClaudeDir: userClaudeDir, cwd: cwd)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    static let on = #"{"permissions":{"blockReadsOutsideWorkingDirectories":true}}"#
    static let off = #"{"permissions":{"blockReadsOutsideWorkingDirectories":false}}"#

    @Test func absentEverywhereIsNoWarning() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        #expect(f.check() == nil)
    }

    @Test func settingsWithoutTheKeyIsNoWarning() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.userSettings, #"{"permissions":{"allow":["Read"]},"model":"opus"}"#)
        try f.write(f.localSettings, #"{"env":{"CROW":"1"}}"#)
        #expect(f.check() == nil)
    }

    @Test func falseIsNoWarning() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.userSettings, Self.off)
        try f.write(f.projectSettings, Self.off)
        try f.write(f.localSettings, Self.off)
        #expect(f.check() == nil)
    }

    @Test func trueInUserSettingsWarns() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.userSettings, Self.on)
        #expect(f.check() == .init(path: f.userSettings))
    }

    @Test func trueInProjectSettingsWarns() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.projectSettings, Self.on)
        #expect(f.check() == .init(path: f.projectSettings))
    }

    @Test func trueInLocalSettingsWarns() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.localSettings, Self.on)
        #expect(f.check() == .init(path: f.localSettings))
    }

    @Test func aMoreSpecificFalseWins() throws {
        // Claude applies local > project > user, so a project `false` turns off a
        // user-level `true` for this launch.
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.userSettings, Self.on)
        try f.write(f.projectSettings, Self.off)
        #expect(f.check() == nil)
    }

    @Test func aMoreSpecificTrueIsTheReportedSource() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.userSettings, Self.off)
        try f.write(f.localSettings, Self.on)
        #expect(f.check() == .init(path: f.localSettings))
    }

    @Test func malformedJSONIsNoWarningAndNoCrash() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.userSettings, #"{"permissions":{"blockReadsOutsideWorkingDirectories":true"#)
        try f.write(f.projectSettings, "not json at all")
        try f.write(f.localSettings, "")
        #expect(f.check() == nil)
    }

    @Test func malformedSpecificFileFallsThroughToTheNextOne() throws {
        // A broken local file doesn't hide a `true` lower down.
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.localSettings, "{")
        try f.write(f.userSettings, Self.on)
        #expect(f.check() == .init(path: f.userSettings))
    }

    @Test func nonBooleanValuesDontCount() {
        for text in [
            #"{"permissions":{"blockReadsOutsideWorkingDirectories":1}}"#,
            #"{"permissions":{"blockReadsOutsideWorkingDirectories":"true"}}"#,
            #"{"permissions":{"blockReadsOutsideWorkingDirectories":null}}"#,
            #"{"permissions":true}"#,
            #"[true]"#,
        ] {
            #expect(ClaudeOutsideReadsBlock.value(in: Data(text.utf8)) == nil, "\(text)")
        }
    }

    @Test func checkNeverWrites() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        try f.write(f.userSettings, Self.on)
        let before = try Data(contentsOf: URL(fileURLWithPath: f.userSettings))
        _ = f.check()
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.userSettings)) == before)
        // No project files appear as a side effect.
        #expect(!FileManager.default.fileExists(atPath: f.projectSettings))
        #expect(!FileManager.default.fileExists(atPath: f.localSettings))
    }

    @Test func settingsFilesAreMostSpecificFirst() {
        #expect(ClaudeOutsideReadsBlock.settingsFiles(userClaudeDir: "/h/.claude", cwd: "/w") == [
            "/w/.claude/settings.local.json",
            "/w/.claude/settings.json",
            "/h/.claude/settings.json",
        ])
    }

    @Test func userClaudeDirHonorsClaudeConfigDir() {
        #expect(ClaudeOutsideReadsBlock.userClaudeDir(environment: [:], home: "/h") == "/h/.claude")
        #expect(ClaudeOutsideReadsBlock.userClaudeDir(
            environment: ["CLAUDE_CONFIG_DIR": "/cfg/claude"], home: "/h") == "/cfg/claude")
        // Blank falls back to the default, as in ChatCommands.Roots.live.
        #expect(ClaudeOutsideReadsBlock.userClaudeDir(
            environment: ["CLAUDE_CONFIG_DIR": "  "], home: "/h") == "/h/.claude")
    }

    @Test func relocatedUserSettingsAreRead() throws {
        let f = try Fixture(); defer { f.cleanUp() }
        let relocated = f.root.appendingPathComponent("cfg").path
        try f.write("\(relocated)/settings.json", Self.on)
        #expect(ClaudeOutsideReadsBlock.check(userClaudeDir: relocated, cwd: f.cwd)
            == .init(path: "\(relocated)/settings.json"))
        // The default location is not consulted instead.
        #expect(f.check() == nil)
    }

    @Test func autoModeLaunchIsKeyedOnTheFlag() {
        let auto = "claude" + ClaudeLaunchArgs.argsSuffix(
            remoteControl: true, sessionName: "Manager", autoPermissionMode: true)
        let manual = "claude" + ClaudeLaunchArgs.argsSuffix(
            remoteControl: true, sessionName: "Manager", autoPermissionMode: false)
        #expect(ClaudeOutsideReadsBlock.isAutoModeLaunch(auto))
        #expect(!ClaudeOutsideReadsBlock.isAutoModeLaunch(manual))
        #expect(!ClaudeOutsideReadsBlock.isAutoModeLaunch(nil))
    }

    @Test func messageNamesTheFileAndTheStall() {
        let message = ClaudeOutsideReadsBlock.Finding(path: "/h/.claude/settings.json").message
        #expect(message.contains("blockReadsOutsideWorkingDirectories"))
        #expect(message.contains("/h/.claude/settings.json"))
        #expect(message.contains("wait for approval"))
    }
}
