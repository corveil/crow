import CrowCore
import Foundation
import Testing
@testable import CrowDaemon

/// Regression coverage for #766: the per-launch dev-root scaffold was lost when
/// `AppDelegate` was deleted (`eb7a489`), so a fresh install brought up a Manager
/// with an empty `{devRoot}/.claude/skills/` and no knowledge of
/// `/crow-workspace`. `LaunchScaffold.run` is the daemon-side replacement,
/// called from `CrowDaemon.run` before `startBoardPoll` ensures the Manager.
@Suite("LaunchScaffold — per-launch dev-root scaffold")
struct LaunchScaffoldTests {

    private static func makeTempDevRoot() throws -> String {
        let unique = "crow-766-\(UUID().uuidString)"
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(unique)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Every bundled skill file the Manager relies on, relative to `.claude/`.
    private static let expectedSkillFiles = [
        "skills/crow-workspace/SKILL.md",
        "skills/crow-workspace/setup.sh",
        "skills/crow-review-pr/SKILL.md",
        "skills/crow-batch-workspace/SKILL.md",
        "skills/crow-create-ticket/SKILL.md",
        "skills/crow-show-image/SKILL.md",
        "skills/crow-attribution/FOOTER.md",
    ]

    @Test func configuredDevRootGetsSkillsAndClaudeMD() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // Fresh install shape: the dev root exists but `.claude/` does not.
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")

        LaunchScaffold.run(devRoot: devRoot, configured: true)

        let fm = FileManager.default
        for relative in Self.expectedSkillFiles {
            let path = (claudeDir as NSString).appendingPathComponent(relative)
            #expect(fm.fileExists(atPath: path), "missing bundled skill file: \(relative)")
        }
        #expect(fm.fileExists(atPath: (claudeDir as NSString).appendingPathComponent("CLAUDE.md")))
        #expect(fm.fileExists(atPath: (claudeDir as NSString).appendingPathComponent("settings.local.json")))
        #expect(fm.fileExists(atPath: (claudeDir as NSString).appendingPathComponent("commands/crow-image.md")))
    }

    /// The upgrade case: an existing dev root whose skills are stale must be
    /// refreshed to the latest bundled version, not left alone.
    @Test func staleSkillsAreRefreshed() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let skillPath = (devRoot as NSString)
            .appendingPathComponent(".claude/skills/crow-workspace/SKILL.md")
        try FileManager.default.createDirectory(
            atPath: (skillPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "# stale from an older Crow\n".write(toFile: skillPath, atomically: true, encoding: .utf8)

        LaunchScaffold.run(devRoot: devRoot, configured: true)

        let refreshed = try String(contentsOfFile: skillPath, encoding: .utf8)
        #expect(!refreshed.contains("stale from an older Crow"))
        #expect(refreshed.contains("crow-workspace"))
    }

    /// `DaemonOptions.parse` falls back to the current working directory when
    /// nothing is configured. Scaffolding that would scatter `.claude/skills/`
    /// into whatever directory `crowd` was started from, so the unconfigured
    /// case must be a complete no-op.
    @Test func unconfiguredDevRootIsNotScaffolded() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let warning = LaunchScaffold.run(devRoot: devRoot, configured: false)

        #expect(warning == nil)
        #expect(!FileManager.default.fileExists(
            atPath: (devRoot as NSString).appendingPathComponent(".claude")))
    }

    /// Running on every launch is only safe if it is genuinely idempotent: the
    /// user's `## Known Issues / Corrections` block in `CLAUDE.md` and their
    /// hand-added `settings.local.json` permissions must survive a second pass
    /// (`Scaffolder.mergeSettings`, covered in depth by
    /// `ScaffolderSettingsMergeTests`).
    @Test func rerunPreservesUserCorrectionsAndSettings() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")

        LaunchScaffold.run(devRoot: devRoot, configured: true)

        // Simulate the user editing both files between launches.
        let claudeMDPath = (claudeDir as NSString).appendingPathComponent("CLAUDE.md")
        let base = try String(contentsOfFile: claudeMDPath, encoding: .utf8)
        let marker = "- `crow send` needs a trailing newline to submit."
        try (base + "\n\(marker)\n").write(toFile: claudeMDPath, atomically: true, encoding: .utf8)

        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.local.json")
        var settings = try String(contentsOfFile: settingsPath, encoding: .utf8)
        settings = settings.replacingOccurrences(
            of: "\"allow\": [", with: "\"allow\": [\n      \"Bash(npm test:*)\",")
        try settings.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        LaunchScaffold.run(devRoot: devRoot, configured: true)

        let claudeMDAfter = try String(contentsOfFile: claudeMDPath, encoding: .utf8)
        #expect(claudeMDAfter.contains("## Known Issues / Corrections"))
        #expect(claudeMDAfter.contains(marker))
        let settingsAfter = try String(contentsOfFile: settingsPath, encoding: .utf8)
        #expect(settingsAfter.contains("Bash(npm test:*)"))
    }
}
