import Foundation
import Testing
import CrowCore
@testable import CrowClaude

/// Re-homes the manager-hook secret-permission invariant dropped with the root
/// suite (`ManagerHookConfigTests`, CROW-607). `writeGatewayEnv` is the only
/// `0o600` path in `ClaudeHookConfigWriter`: the `env` block can carry a
/// resolved AI-gateway bearer token, so the file it writes
/// (`.claude/settings.local.json`) must be owner-only, matching
/// `ConfigStore`'s `0o600` on `config.json` (CROW-402).
@Suite("ClaudeHookConfigWriter.writeGatewayEnv")
struct ClaudeHookConfigWriterTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-gwenv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settings(at dir: URL) throws -> [String: Any] {
        let path = dir.appendingPathComponent(".claude/settings.local.json")
        let data = try #require(FileManager.default.contents(atPath: path.path))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func posixPerms(at dir: URL) throws -> Int {
        let path = dir.appendingPathComponent(".claude/settings.local.json").path
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return try #require((attrs[.posixPermissions] as? NSNumber)?.intValue)
    }

    @Test func writesGatewayEnvOwnerOnly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        ClaudeHookConfigWriter.writeGatewayEnv(
            dirPath: dir.path,
            resolved: .init(baseURL: "https://gw.example", customHeaders: "X-Api-Key: secret"))

        // The bearer-token-bearing file must be readable only by its owner.
        #expect(try posixPerms(at: dir) == 0o600)

        let env = try #require(try settings(at: dir)["env"] as? [String: Any])
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "https://gw.example")
        #expect(env["ANTHROPIC_CUSTOM_HEADERS"] as? String == "X-Api-Key: secret")
    }

    @Test func clearingRemovesGatewayKeysButPreservesOtherSettings() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Pre-seed a settings file with our gateway keys, an unrelated env var,
        // and an unrelated top-level key — none of which we own.
        let claudeDir = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "env": [
                "ANTHROPIC_BASE_URL": "https://old.gw",
                "ANTHROPIC_CUSTOM_HEADERS": "X-Api-Key: old",
                "USER_VAR": "keep-me",
            ],
            "permissions": ["allow": ["Bash"]],
        ]
        let seedData = try JSONSerialization.data(withJSONObject: seed)
        try seedData.write(to: claudeDir.appendingPathComponent("settings.local.json"))

        ClaudeHookConfigWriter.writeGatewayEnv(dirPath: dir.path, resolved: nil)

        let merged = try settings(at: dir)
        let env = try #require(merged["env"] as? [String: Any])
        #expect(env["ANTHROPIC_BASE_URL"] == nil)          // gateway keys cleared…
        #expect(env["ANTHROPIC_CUSTOM_HEADERS"] == nil)
        #expect(env["USER_VAR"] as? String == "keep-me")   // …unrelated env var preserved
        #expect(merged["permissions"] != nil)              // unrelated top-level key preserved
        // Re-write still restricts the file (unrelated USER_VAR could be secret too).
        #expect(try posixPerms(at: dir) == 0o600)
    }
}

/// #897: a hook command must never name a build product. An old dev build baked
/// its own `.build/{arch}/debug/crow` into every command it wrote; when that
/// worktree was reaped the commands became permanently dangling, so every hook
/// event failed and all telemetry from that directory was silently lost.
@Suite("ClaudeHookConfigWriter crow-path resolution")
struct ClaudeHookConfigWriterCrowPathTests {
    /// A temp dev root plus a fake "app binary" living under a `.build/` tree,
    /// standing in for a `swift build` product inside a worktree.
    private func makeDevRootWithBuildProduct() throws -> (devRoot: URL, appBinary: String) {
        let devRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-crowpath-\(UUID().uuidString)")
        let buildDir = devRoot.appendingPathComponent(".build/arm64-apple-macosx/debug")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        let binary = buildDir.appendingPathComponent("crow")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return (devRoot, binary.path)
    }

    @Test func resolveReturnsStableSymlinkNotBuildProduct() throws {
        let (devRoot, appBinary) = try makeDevRootWithBuildProduct()
        defer { try? FileManager.default.removeItem(at: devRoot) }

        let resolved = try #require(
            ClaudeHookConfigWriter.resolveCrowBinary(devRoot: devRoot.path, appCrowPath: appBinary))

        #expect(resolved == devRoot.appendingPathComponent(".claude/bin/crow").path)
        #expect(!resolved.contains("/.build/"))
        // The link is what makes the path stable; its target is the build product.
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: resolved) == appBinary)
    }

    /// The issue's explicit acceptance criterion.
    @Test func generatedCommandsNeverContainABuildPath() throws {
        let (devRoot, appBinary) = try makeDevRootWithBuildProduct()
        defer { try? FileManager.default.removeItem(at: devRoot) }

        let crowPath = try #require(
            ClaudeHookConfigWriter.resolveCrowBinary(devRoot: devRoot.path, appCrowPath: appBinary))
        let hooks = ClaudeHookConfigWriter.generateHooks(sessionID: UUID(), crowPath: crowPath)

        #expect(hooks.count == ClaudeHookConfigWriter.allEvents.count)
        for event in ClaudeHookConfigWriter.allEvents {
            let groups = try #require(hooks[event] as? [[String: Any]])
            let entries = try #require(groups.first?["hooks"] as? [[String: Any]])
            let command = try #require(entries.first?["command"] as? String)
            #expect(!command.contains("/.build/"), "\(event) command names a build product: \(command)")
        }
    }

    /// A dev root containing a space used to kill all 17 hooks: the path was
    /// interpolated raw into a command Claude runs through `/bin/sh -c`.
    @Test func commandsAreShellSafeForDevRootsContainingSpaces() throws {
        let session = UUID()
        let command = ClaudeHookConfigWriter.hookCommand(
            crowPath: "/Users/x/My Dev/.claude/bin/crow", sessionID: session, event: "Stop")

        #expect(command.hasPrefix("'/Users/x/My Dev/.claude/bin/crow' "))
        let parsed = try #require(ClaudeHookRepair.parseCrowHookCommand(command))
        #expect(parsed.binary == "/Users/x/My Dev/.claude/bin/crow")
        #expect(parsed.sessionID == session)
        #expect(parsed.event == "Stop")
    }

    @Test func ensureRepairsADanglingLinkAndIsIdempotent() throws {
        let (devRoot, appBinary) = try makeDevRootWithBuildProduct()
        defer { try? FileManager.default.removeItem(at: devRoot) }
        let fm = FileManager.default
        let binDir = devRoot.appendingPathComponent(".claude/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let link = binDir.appendingPathComponent("crow").path

        // A link left over from a worktree that has since been deleted.
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "/nonexistent/gone/crow")

        #expect(ClaudeHookConfigWriter.ensureCrowCLISymlink(devRoot: devRoot.path, appCrowPath: appBinary) == link)
        #expect(try fm.destinationOfSymbolicLink(atPath: link) == appBinary)

        // Second pass must not unlink+relink — that window is one where a
        // concurrently firing hook sees ENOENT.
        let inodeBefore = try #require(
            (try fm.attributesOfItem(atPath: link)[.systemFileNumber] as? NSNumber)?.uint64Value)
        #expect(ClaudeHookConfigWriter.ensureCrowCLISymlink(devRoot: devRoot.path, appCrowPath: appBinary) == link)
        let inodeAfter = try #require(
            (try fm.attributesOfItem(atPath: link)[.systemFileNumber] as? NSNumber)?.uint64Value)
        #expect(inodeBefore == inodeAfter)
    }

    @Test func ensureNeverReplacesANonSymlinkFile() throws {
        let (devRoot, appBinary) = try makeDevRootWithBuildProduct()
        defer { try? FileManager.default.removeItem(at: devRoot) }
        let fm = FileManager.default
        let binDir = devRoot.appendingPathComponent(".claude/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let link = binDir.appendingPathComponent("crow")
        try Data("user's own script".utf8).write(to: link)

        _ = ClaudeHookConfigWriter.ensureCrowCLISymlink(devRoot: devRoot.path, appCrowPath: appBinary)

        // Still the user's file, untouched — we only ever own symlinks here.
        #expect(try String(contentsOf: link, encoding: .utf8) == "user's own script")
        let attrs = try fm.attributesOfItem(atPath: link.path)
        #expect((attrs[.type] as? FileAttributeType) != .typeSymbolicLink)
    }

    /// #915: `{devRoot}/.claude/bin` was found empty on a real install while
    /// still first on PATH, and the writer fell through to a `.build/` path —
    /// already stale on arrival. A second stable anchor outside the dev root
    /// keeps hook commands durable when the first one can't be made.
    @Test func fallsBackToAStableLinkOutsideAnUnusableDevRoot() throws {
        let (devRoot, appBinary) = try makeDevRootWithBuildProduct()
        defer { try? FileManager.default.removeItem(at: devRoot) }
        let fm = FileManager.default
        // A regular file where `.claude/bin` must be: the directory can never
        // be created, so the dev-root link is unavailable.
        try fm.createDirectory(
            at: devRoot.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: devRoot.appendingPathComponent(".claude/bin"))

        let fallback = devRoot.appendingPathComponent("elsewhere/bin/crow").path
        let resolved = try #require(ClaudeHookConfigWriter.resolveCrowBinary(
            devRoot: devRoot.path, appCrowPath: appBinary, stableFallbackLink: fallback))

        #expect(resolved == fallback)
        #expect(!resolved.contains("/.build/"))
        #expect(try fm.destinationOfSymbolicLink(atPath: resolved) == appBinary)
    }

    /// With no stable anchor available at all, refuse rather than bake in a
    /// build product. The caller writes no hook block — that session loses
    /// telemetry, but a dangling block outlives its session and breaks every
    /// worktree of the repo that inherits it (#915).
    @Test func refusesToEmitABuildProductWhenNoStableLinkIsPossible() throws {
        let (devRoot, appBinary) = try makeDevRootWithBuildProduct()
        defer { try? FileManager.default.removeItem(at: devRoot) }
        let fm = FileManager.default
        try fm.createDirectory(
            at: devRoot.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: devRoot.appendingPathComponent(".claude/bin"))
        try Data("also not a directory".utf8).write(to: devRoot.appendingPathComponent("blocked"))

        #expect(ClaudeHookConfigWriter.resolveCrowBinary(
            devRoot: devRoot.path, appCrowPath: appBinary,
            stableFallbackLink: devRoot.appendingPathComponent("blocked/bin/crow").path) == nil)
    }

    /// A real install on PATH is already stable, so it is returned directly
    /// rather than refused when neither link can be made.
    @Test func acceptsANonBuildBinaryWhenNoStableLinkIsPossible() throws {
        let devRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-crowpath-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: devRoot) }
        let fm = FileManager.default
        try fm.createDirectory(at: devRoot, withIntermediateDirectories: true)
        let installed = devRoot.appendingPathComponent("usr-local-bin-crow")
        try Data("#!/bin/sh\n".utf8).write(to: installed)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed.path)
        try Data("not a directory".utf8).write(to: devRoot.appendingPathComponent("blocked"))

        #expect(ClaudeHookConfigWriter.resolveCrowBinary(
            devRoot: nil, appCrowPath: installed.path,
            stableFallbackLink: devRoot.appendingPathComponent("blocked/bin/crow").path)
                == installed.path)
    }
}
