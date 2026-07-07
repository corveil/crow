import Foundation
import Testing
@testable import CrowClaude

/// Tests for CROW-600: seeding worktree trust into ~/.claude.json so Claude
/// Code's "Do you trust the files in this folder?" dialog never blocks an
/// auto-launched session. Mirrors the ScaffolderSettingsMergeTests pattern:
/// temp files + JSONSerialization round-trip assertions.
@Suite struct ClaudeTrustSeederTests {

    private func makeTempDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-trust-seeder-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readJSON(_ path: String) throws -> [String: Any] {
        let data = try #require(FileManager.default.contents(atPath: path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func trustEntry(_ root: [String: Any], _ projectPath: String) -> [String: Any]? {
        (root["projects"] as? [String: Any])?[projectPath] as? [String: Any]
    }

    @Test func missingFileIsCreatedWithTrustKeysAndOwnerOnlyPerms() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .seeded)
        let root = try readJSON(jsonPath)
        let entry = try #require(trustEntry(root, dir))
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
        #expect(entry["hasCompletedProjectOnboarding"] as? Bool == true)

        let attrs = try FileManager.default.attributesOfItem(atPath: jsonPath)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect(perms.uint16Value == 0o600)
    }

    @Test func mergePreservesOtherProjectsAndTopLevelKeys() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        let existing: [String: Any] = [
            "numStartups": 42,
            "oauthAccount": ["emailAddress": "user@example.com", "uuid": "abc-123"],
            "mcpServers": ["jira": ["command": "uvx", "args": ["mcp-atlassian"]]],
            "projects": [
                "/Users/someone/other-project": [
                    "hasTrustDialogAccepted": true,
                    "allowedTools": ["Bash(git status:*)"],
                    "history": [["display": "hi"]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: URL(fileURLWithPath: jsonPath))

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .seeded)
        let root = try readJSON(jsonPath)
        #expect(root["numStartups"] as? Int == 42)
        let oauth = try #require(root["oauthAccount"] as? [String: Any])
        #expect(oauth["emailAddress"] as? String == "user@example.com")
        let mcp = try #require(root["mcpServers"] as? [String: Any])
        #expect((mcp["jira"] as? [String: Any])?["command"] as? String == "uvx")

        let other = try #require(trustEntry(root, "/Users/someone/other-project"))
        #expect(other["hasTrustDialogAccepted"] as? Bool == true)
        #expect(other["allowedTools"] as? [String] == ["Bash(git status:*)"])
        #expect((other["history"] as? [[String: Any]])?.first?["display"] as? String == "hi")

        let entry = try #require(trustEntry(root, dir))
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
        #expect(entry["hasCompletedProjectOnboarding"] as? Bool == true)
    }

    @Test func untrustedEntryIsFlippedTrueWithSiblingKeysIntact() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        let existing: [String: Any] = [
            "projects": [
                dir: [
                    "hasTrustDialogAccepted": false,
                    "allowedTools": ["Bash(ls:*)"],
                    "projectOnboardingSeenCount": 3,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: URL(fileURLWithPath: jsonPath))

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .seeded)
        let entry = try #require(trustEntry(try readJSON(jsonPath), dir))
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
        #expect(entry["hasCompletedProjectOnboarding"] as? Bool == true)
        #expect(entry["allowedTools"] as? [String] == ["Bash(ls:*)"])
        #expect(entry["projectOnboardingSeenCount"] as? Int == 3)
    }

    @Test func alreadyTrustedSkipsRewriteAndLeavesFileAlone() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        let existing: [String: Any] = [
            "projects": [
                dir: [
                    "hasTrustDialogAccepted": true,
                    "hasCompletedProjectOnboarding": true,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: URL(fileURLWithPath: jsonPath))
        let bytesBefore = try #require(FileManager.default.contents(atPath: jsonPath))

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .alreadyTrusted)
        let bytesAfter = try #require(FileManager.default.contents(atPath: jsonPath))
        #expect(bytesAfter == bytesBefore)
    }

    @Test func unparseableFileIsLeftUntouched() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        let garbage = "{not json"
        try garbage.write(toFile: jsonPath, atomically: true, encoding: .utf8)

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .skippedUnparseable)
        #expect(try String(contentsOfFile: jsonPath, encoding: .utf8) == garbage)
    }

    @Test func topLevelArrayIsLeftUntouched() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        let array = "[1, 2, 3]"
        try array.write(toFile: jsonPath, atomically: true, encoding: .utf8)

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .skippedUnparseable)
        #expect(try String(contentsOfFile: jsonPath, encoding: .utf8) == array)
    }

    @Test func missingProjectsKeyIsAddedWithoutDisturbingTopLevel() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        try JSONSerialization.data(withJSONObject: ["numStartups": 7])
            .write(to: URL(fileURLWithPath: jsonPath))

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .seeded)
        let root = try readJSON(jsonPath)
        #expect(root["numStartups"] as? Int == 7)
        let entry = try #require(trustEntry(root, dir))
        #expect(entry["hasTrustDialogAccepted"] as? Bool == true)
    }

    @Test func existingFilePermissionsArePreservedOnRewrite() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        try JSONSerialization.data(withJSONObject: ["projects": [:]])
            .write(to: URL(fileURLWithPath: jsonPath))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: jsonPath)

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: dir, claudeJSONPath: jsonPath)

        #expect(outcome == .seeded)
        let attrs = try FileManager.default.attributesOfItem(atPath: jsonPath)
        let perms = try #require(attrs[.posixPermissions] as? NSNumber)
        #expect(perms.uint16Value == 0o644)
    }

    @Test func symlinkedProjectPathTrustsBothSpellings() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let jsonPath = (dir as NSString).appendingPathComponent("claude.json")
        let realProject = (dir as NSString).appendingPathComponent("real-project")
        try FileManager.default.createDirectory(atPath: realProject, withIntermediateDirectories: true)
        let linkPath = (dir as NSString).appendingPathComponent("link-project")
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realProject)

        let outcome = ClaudeTrustSeeder.seedTrust(projectPath: linkPath, claudeJSONPath: jsonPath)

        #expect(outcome == .seeded)
        let root = try readJSON(jsonPath)
        let literal = try #require(trustEntry(root, linkPath))
        #expect(literal["hasTrustDialogAccepted"] as? Bool == true)
        let resolvedPath = URL(fileURLWithPath: linkPath).resolvingSymlinksInPath().path
        #expect(resolvedPath != linkPath)
        let resolved = try #require(trustEntry(root, resolvedPath))
        #expect(resolved["hasTrustDialogAccepted"] as? Bool == true)
    }
}
