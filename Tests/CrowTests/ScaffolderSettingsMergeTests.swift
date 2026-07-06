import CrowCore
import Foundation
import Testing
@testable import Crow

/// Coverage for `Scaffolder.mergeSettings`: settings.json used to
/// be overwritten wholesale on every launch, silently discarding anything a
/// user added by hand. Crow now writes its required permissions to
/// settings.local.json instead, and never touches settings.json at all —
/// that file is the user's own. These tests exercise the merge directly,
/// plus the full `scaffold(...)` entry point to confirm a user's
/// settings.local.json survives repeat launches and settings.json is left
/// completely alone.
@Suite("Scaffolder settings.local.json merge")
struct ScaffolderSettingsMergeTests {

    private static func makeTempDevRoot() throws -> String {
        let base = NSTemporaryDirectory()
        let unique = "crow-593-\(UUID().uuidString)"
        let path = (base as NSString).appendingPathComponent(unique)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static let template = """
    {
      "permissions": {
        "allow": ["Bash(crow *)", "Bash(gh pr view:*)"]
      },
      "sandbox": {
        "enabled": true
      }
    }
    """

    @Test func noExistingFileFallsBackToTemplateVerbatim() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let missingPath = (devRoot as NSString).appendingPathComponent("settings.json")

        let result = Scaffolder.mergeSettings(existingPath: missingPath, template: Self.template)
        #expect(result == Self.template)
    }

    @Test func userAddedPermissionSurvives() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(crow *)", "Bash(gh pr view:*)", "Bash(npm test:*)"]
          },
          "sandbox": {
            "enabled": true
          }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let result = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let allow = try #require((obj["permissions"] as? [String: Any])?["allow"] as? [String])
        #expect(Set(allow) == Set(["Bash(crow *)", "Bash(gh pr view:*)", "Bash(npm test:*)"]))
    }

    @Test func missingBundledPermissionIsAddedBack() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        // User's file is missing the bundled `gh pr view` entry (e.g. from
        // an older Crow version) — it should be added back so `gh` keeps
        // working without a permission prompt.
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(crow *)"]
          },
          "sandbox": {
            "enabled": true
          }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let result = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let allow = try #require((obj["permissions"] as? [String: Any])?["allow"] as? [String])
        #expect(Set(allow).isSuperset(of: ["Bash(crow *)", "Bash(gh pr view:*)"]))
    }

    @Test func customTopLevelKeysArePreserved() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(crow *)", "Bash(gh pr view:*)"]
          },
          "sandbox": {
            "enabled": true
          },
          "outputStyle": "concise",
          "statusLine": {
            "type": "command",
            "command": "~/.claude/statusline.sh"
          },
          "env": {
            "FOO": "bar"
          }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let result = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(obj["outputStyle"] as? String == "concise")
        #expect((obj["statusLine"] as? [String: Any])?["command"] as? String == "~/.claude/statusline.sh")
        #expect((obj["env"] as? [String: Any])?["FOO"] as? String == "bar")
    }

    @Test func userSandboxOverrideWins() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(crow *)", "Bash(gh pr view:*)"]
          },
          "sandbox": {
            "enabled": false
          }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let result = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect((obj["sandbox"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test func nothingToAddLeavesFileByteForByteUntouched() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        // Deliberately odd formatting/key order — must survive verbatim
        // since every template key is already present.
        let existing = """
        {
          "sandbox":   { "enabled": true },
          "permissions": { "allow": ["Bash(gh pr view:*)", "Bash(crow *)"] }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let result = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        #expect(result == existing)
    }

    @Test func fullScaffoldPreservesUserSettingsAcrossRelaunches() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let scaffolder = Scaffolder(devRoot: devRoot)

        _ = try scaffolder.scaffold(workspaceNames: [])

        // Simulate the user hand-editing settings.local.json after first launch.
        let settingsPath = (devRoot as NSString).appendingPathComponent(".claude/settings.local.json")
        var data = try #require(FileManager.default.contents(atPath: settingsPath))
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["outputStyle"] = "concise"
        var perms = obj["permissions"] as? [String: Any] ?? [:]
        var allow = perms["allow"] as? [String] ?? []
        allow.append("Bash(npm test:*)")
        perms["allow"] = allow
        obj["permissions"] = perms
        data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: URL(fileURLWithPath: settingsPath))

        // Relaunch: scaffold runs again, as it does on every app launch.
        _ = try scaffolder.scaffold(workspaceNames: [])

        let reloaded = try #require(FileManager.default.contents(atPath: settingsPath))
        let reloadedObj = try #require(try JSONSerialization.jsonObject(with: reloaded) as? [String: Any])
        #expect(reloadedObj["outputStyle"] as? String == "concise")
        let reloadedAllow = try #require((reloadedObj["permissions"] as? [String: Any])?["allow"] as? [String])
        #expect(reloadedAllow.contains("Bash(npm test:*)"))
    }

    @Test func scaffoldNeverCreatesSettingsJSON() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        _ = try Scaffolder(devRoot: devRoot).scaffold(workspaceNames: [])

        let settingsJSONPath = (devRoot as NSString).appendingPathComponent(".claude/settings.json")
        let settingsLocalPath = (devRoot as NSString).appendingPathComponent(".claude/settings.local.json")
        #expect(!FileManager.default.fileExists(atPath: settingsJSONPath))
        #expect(FileManager.default.fileExists(atPath: settingsLocalPath))
    }

    @Test func scaffoldNeverTouchesAPreExistingSettingsJSON() throws {
        // A user's own settings.json — Crow must never read or write it,
        // even if one happens to already exist at the devRoot (e.g. hand
        // authored, or left over from an older Crow version that used to
        // write settings.json directly).
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let settingsJSONPath = (claudeDir as NSString).appendingPathComponent("settings.json")
        let userContent = "{\n  \"outputStyle\": \"my-own-file-leave-it-alone\"\n}"
        try userContent.write(toFile: settingsJSONPath, atomically: true, encoding: .utf8)

        _ = try Scaffolder(devRoot: devRoot).scaffold(workspaceNames: [])

        let after = try String(contentsOfFile: settingsJSONPath, encoding: .utf8)
        #expect(after == userContent)
    }
}
