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

    /// Unwrap the payload of a `.write` outcome; returns `nil` (→ a test
    /// failure at the `#require` call site) when the merge reported
    /// `.upToDate` and thus wouldn't have written anything.
    private static func writtenContent(_ outcome: Scaffolder.SettingsMergeOutcome) -> String? {
        guard case let .write(content) = outcome else { return nil }
        return content
    }

    @Test func noExistingFileFallsBackToTemplateVerbatim() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let missingPath = (devRoot as NSString).appendingPathComponent("settings.json")

        let result = Scaffolder.mergeSettings(existingPath: missingPath, template: Self.template)
        #expect(result == .write(Self.template))
    }

    @Test func userAddedPermissionSurvives() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        // User added `Bash(npm test:*)` and (say, from an older Crow) is
        // missing the bundled `Bash(gh pr view:*)`. The merge must add the
        // bundled entry back *and* keep the user's — a write, not a skip.
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(crow *)", "Bash(npm test:*)"]
          },
          "sandbox": {
            "enabled": true
          }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let outcome = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let result = try #require(Self.writtenContent(outcome))
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

        let outcome = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let result = try #require(Self.writtenContent(outcome))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        let allow = try #require((obj["permissions"] as? [String: Any])?["allow"] as? [String])
        #expect(Set(allow).isSuperset(of: ["Bash(crow *)", "Bash(gh pr view:*)"]))
    }

    @Test func customTopLevelKeysArePreserved() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        // Missing the bundled `gh pr view` entry so the merge actually
        // writes — the point is that the custom top-level keys ride along
        // untouched in that written output.
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(crow *)"]
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

        let outcome = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let result = try #require(Self.writtenContent(outcome))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(obj["outputStyle"] as? String == "concise")
        #expect((obj["statusLine"] as? [String: Any])?["command"] as? String == "~/.claude/statusline.sh")
        #expect((obj["env"] as? [String: Any])?["FOO"] as? String == "bar")
    }

    @Test func userSandboxOverrideWins() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        // Missing the bundled `gh pr view` entry so the merge writes; the
        // user's `sandbox.enabled = false` must survive into that output
        // rather than being reset to the template's `true`.
        let existing = """
        {
          "permissions": {
            "allow": ["Bash(crow *)"]
          },
          "sandbox": {
            "enabled": false
          }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let outcome = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        let result = try #require(Self.writtenContent(outcome))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect((obj["sandbox"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test func nothingToAddReportsUpToDate() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let path = (devRoot as NSString).appendingPathComponent("settings.json")
        // Deliberately odd formatting/key order. Every template key is
        // already present, so the merge reports `.upToDate` — the caller
        // then skips the write, leaving the file byte-for-byte (and
        // inode/mtime/mode) untouched.
        let existing = """
        {
          "sandbox":   { "enabled": true },
          "permissions": { "allow": ["Bash(gh pr view:*)", "Bash(crow *)"] }
        }
        """
        try existing.write(toFile: path, atomically: true, encoding: .utf8)

        let result = Scaffolder.mergeSettings(existingPath: path, template: Self.template)
        #expect(result == .upToDate)
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

    // MARK: - File mode + write-skip (CROW-595 review round-trip)

    /// settings.local.json's `env` block can carry a resolved gateway bearer
    /// token, so scaffold must write it owner-only (0o600) — matching the
    /// sibling `ClaudeHookConfigWriter.writeGatewayEnv`. `atomically: true`
    /// alone resets the mode to the umask default (~0o644).
    @Test func freshScaffoldWritesSettingsLocalOwnerOnly() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        _ = try Scaffolder(devRoot: devRoot).scaffold(workspaceNames: [])

        let settingsPath = (devRoot as NSString).appendingPathComponent(".claude/settings.local.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: settingsPath)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    /// In the steady state (nothing to add) scaffold must not rewrite the
    /// file at all — otherwise every launch churns a new inode/mtime and the
    /// `atomically: true` rename would relax the mode. Proven by relaxing the
    /// mode after the first scaffold and confirming a second scaffold leaves
    /// both the inode and that relaxed mode exactly as-is.
    @Test func steadyStateScaffoldSkipsRewriteAndLeavesFileAlone() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let scaffolder = Scaffolder(devRoot: devRoot)

        _ = try scaffolder.scaffold(workspaceNames: [])

        let settingsPath = (devRoot as NSString).appendingPathComponent(".claude/settings.local.json")
        let firstInode = try #require(
            (try FileManager.default.attributesOfItem(atPath: settingsPath))[.systemFileNumber] as? Int)
        // A distinctive mode no code path would ever set on its own; if the
        // second scaffold rewrites, atomically:true + our 0o600 re-apply
        // would erase it.
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: settingsPath)

        _ = try scaffolder.scaffold(workspaceNames: [])

        let afterAttrs = try FileManager.default.attributesOfItem(atPath: settingsPath)
        #expect((afterAttrs[.systemFileNumber] as? Int) == firstInode)
        #expect((afterAttrs[.posixPermissions] as? Int) == 0o640)
    }

    /// The Settings → "Re-scaffold" action runs scaffold with no following
    /// `writeGatewayEnv`, so scaffold itself must restore 0o600 whenever it
    /// writes. Drop a bundled permission (forcing a write) and relax the mode
    /// the way an atomic rewrite would; the re-scaffold must both add the
    /// permission back and re-restrict the file to owner-only.
    @Test func rescaffoldReAddsMissingPermissionAndRestoresOwnerOnly() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let scaffolder = Scaffolder(devRoot: devRoot)

        _ = try scaffolder.scaffold(workspaceNames: [])

        let settingsPath = (devRoot as NSString).appendingPathComponent(".claude/settings.local.json")
        let firstData = try #require(FileManager.default.contents(atPath: settingsPath))
        var obj = try #require(try JSONSerialization.jsonObject(with: firstData) as? [String: Any])
        var perms = try #require(obj["permissions"] as? [String: Any])
        var allow = try #require(perms["allow"] as? [String])
        let dropped = try #require(allow.first)
        allow.removeAll { $0 == dropped }
        perms["allow"] = allow
        obj["permissions"] = perms
        try JSONSerialization.data(withJSONObject: obj).write(to: URL(fileURLWithPath: settingsPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settingsPath)

        _ = try scaffolder.scaffold(workspaceNames: [])

        let reloaded = try #require(FileManager.default.contents(atPath: settingsPath))
        let reloadedObj = try #require(try JSONSerialization.jsonObject(with: reloaded) as? [String: Any])
        let reloadedAllow = try #require((reloadedObj["permissions"] as? [String: Any])?["allow"] as? [String])
        #expect(reloadedAllow.contains(dropped))
        let attrs = try FileManager.default.attributesOfItem(atPath: settingsPath)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }
}
