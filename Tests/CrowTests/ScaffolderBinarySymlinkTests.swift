import CrowCore
import Foundation
import Testing
@testable import Crow

/// Coverage for the per-devroot bin-dir symlink farm that `Scaffolder` builds
/// from `defaults.binaries` (CROW-487). Combined with the tmux shell wrapper's
/// post-rc PATH prepend, this farm gives configured binaries precedence over
/// whatever's on PATH inside spawned agent terminals.
///
/// We exercise the public `scaffold(...)` entry point against a tmp devRoot
/// instead of the private helper — the loop runs late in scaffold and we want
/// the integration to be wired up, not just the helper in isolation.
@Suite("Scaffolder binary symlinks")
struct ScaffolderBinarySymlinkTests {

    private static func makeTempDevRoot() throws -> String {
        let base = NSTemporaryDirectory()
        let unique = "crow-487-\(UUID().uuidString)"
        let path = (base as NSString).appendingPathComponent(unique)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Lay down a tiny executable shell script and return its absolute path.
    /// Cheap stand-in for a real configured binary — the symlink loop only
    /// checks `isExecutableFile`, not what the file actually does.
    private static func makeExecutable(in dir: String, name: String) throws -> String {
        let path = (dir as NSString).appendingPathComponent(name)
        try "#!/bin/sh\necho \(name)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @Test func executableTargetsBecomeSymlinks() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let corveilPath = try Self.makeExecutable(in: toolsDir, name: "corveil")
        let codexPath = try Self.makeExecutable(in: toolsDir, name: "codex")

        _ = try Scaffolder(devRoot: devRoot).scaffold(
            workspaceNames: [],
            binaryOverrides: ["corveil": corveilPath, "codex": codexPath]
        )

        let binDir = (devRoot as NSString).appendingPathComponent(".claude/bin")
        let corveilLink = (binDir as NSString).appendingPathComponent("corveil")
        let codexLink = (binDir as NSString).appendingPathComponent("codex")

        #expect(FileManager.default.fileExists(atPath: corveilLink))
        #expect(FileManager.default.fileExists(atPath: codexLink))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: corveilLink) == corveilPath)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: codexLink) == codexPath)
    }

    @Test func nonExecutableTargetIsSkipped() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // Existing file but not executable — should be skipped, no symlink.
        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let nonExec = (toolsDir as NSString).appendingPathComponent("corveil")
        try "not executable".write(toFile: nonExec, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExec)

        _ = try Scaffolder(devRoot: devRoot).scaffold(
            workspaceNames: [],
            binaryOverrides: ["corveil": nonExec]
        )

        let corveilLink = (devRoot as NSString)
            .appendingPathComponent(".claude/bin/corveil")
        #expect(!FileManager.default.fileExists(atPath: corveilLink))
    }

    @Test func nonexistentTargetIsSkipped() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        _ = try Scaffolder(devRoot: devRoot).scaffold(
            workspaceNames: [],
            binaryOverrides: ["corveil": "/path/that/does/not/exist/crow487"]
        )

        let corveilLink = (devRoot as NSString)
            .appendingPathComponent(".claude/bin/corveil")
        #expect(!FileManager.default.fileExists(atPath: corveilLink))
    }

    @Test func staleSymlinkIsReapedWhenKeyRemoved() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let corveilPath = try Self.makeExecutable(in: toolsDir, name: "corveil")

        let scaffolder = Scaffolder(devRoot: devRoot)
        // First pass: corveil is configured -> link created.
        _ = try scaffolder.scaffold(
            workspaceNames: [],
            binaryOverrides: ["corveil": corveilPath]
        )
        let corveilLink = (devRoot as NSString)
            .appendingPathComponent(".claude/bin/corveil")
        #expect(FileManager.default.fileExists(atPath: corveilLink))

        // Second pass: user cleared the setting -> stale link reaped.
        _ = try scaffolder.scaffold(workspaceNames: [], binaryOverrides: [:])
        #expect(!FileManager.default.fileExists(atPath: corveilLink))
    }

    @Test func nonSymlinkFilesInBinDirAreLeftAlone() throws {
        // Defensive: if a user (or a future Crow feature) drops a real file
        // into `.claude/bin`, the reaper must not nuke it. Only symlinks we
        // own should ever disappear.
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let binDir = (devRoot as NSString).appendingPathComponent(".claude/bin")
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let strangerFile = (binDir as NSString).appendingPathComponent("stranger")
        try "user dropped this".write(toFile: strangerFile, atomically: true, encoding: .utf8)

        _ = try Scaffolder(devRoot: devRoot).scaffold(workspaceNames: [], binaryOverrides: [:])

        #expect(FileManager.default.fileExists(atPath: strangerFile))
    }

    @Test func reconfigurationRepointsExistingSymlink() throws {
        // When the user picks a different binary path for the same key, the
        // symlink should re-point — matches `ln -sf` semantics and prevents
        // a stale link from quietly resolving to the prior path.
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let firstPath = try Self.makeExecutable(in: toolsDir, name: "corveil-a")
        let secondPath = try Self.makeExecutable(in: toolsDir, name: "corveil-b")

        let scaffolder = Scaffolder(devRoot: devRoot)
        _ = try scaffolder.scaffold(workspaceNames: [], binaryOverrides: ["corveil": firstPath])
        _ = try scaffolder.scaffold(workspaceNames: [], binaryOverrides: ["corveil": secondPath])

        let corveilLink = (devRoot as NSString)
            .appendingPathComponent(".claude/bin/corveil")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: corveilLink) == secondPath)
    }

    @Test func crowCLISymlinkAlwaysMaterialized() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let appCrowPath = try Self.makeExecutable(in: toolsDir, name: "crow-app")

        _ = try Scaffolder(devRoot: devRoot).scaffold(
            workspaceNames: [],
            appCrowBinaryPath: appCrowPath
        )

        let crowLink = (devRoot as NSString).appendingPathComponent(".claude/bin/crow")
        #expect(FileManager.default.fileExists(atPath: crowLink))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: crowLink) == appCrowPath)
    }

    @Test func crowCLISymlinkSurvivesEmptyBinaryOverrides() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let appCrowPath = try Self.makeExecutable(in: toolsDir, name: "crow-app")

        let scaffolder = Scaffolder(devRoot: devRoot)
        _ = try scaffolder.scaffold(workspaceNames: [], appCrowBinaryPath: appCrowPath)
        let crowLink = (devRoot as NSString).appendingPathComponent(".claude/bin/crow")
        #expect(FileManager.default.fileExists(atPath: crowLink))

        _ = try scaffolder.scaffold(workspaceNames: [], binaryOverrides: [:], appCrowBinaryPath: appCrowPath)
        #expect(FileManager.default.fileExists(atPath: crowLink))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: crowLink) == appCrowPath)
    }

    @Test func crowCLISymlinkRepointsWhenAppBinaryChanges() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let firstPath = try Self.makeExecutable(in: toolsDir, name: "crow-a")
        let secondPath = try Self.makeExecutable(in: toolsDir, name: "crow-b")

        let scaffolder = Scaffolder(devRoot: devRoot)
        _ = try scaffolder.scaffold(workspaceNames: [], appCrowBinaryPath: firstPath)
        _ = try scaffolder.scaffold(workspaceNames: [], appCrowBinaryPath: secondPath)

        let crowLink = (devRoot as NSString).appendingPathComponent(".claude/bin/crow")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: crowLink) == secondPath)
    }

    @Test func crowCLISymlinkRepairsDanglingLinkWhenTargetDeleted() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let firstPath = try Self.makeExecutable(in: toolsDir, name: "crow-old")
        let secondPath = try Self.makeExecutable(in: toolsDir, name: "crow-new")

        let scaffolder = Scaffolder(devRoot: devRoot)
        _ = try scaffolder.scaffold(workspaceNames: [], appCrowBinaryPath: firstPath)

        // Simulate the app binary moving (e.g. Crow.app drag to /Applications):
        // the symlink target is gone but the link inode remains dangling.
        try FileManager.default.removeItem(atPath: firstPath)

        let crowLink = (devRoot as NSString).appendingPathComponent(".claude/bin/crow")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: crowLink) == firstPath)
        #expect(!FileManager.default.isExecutableFile(atPath: crowLink))

        _ = try scaffolder.scaffold(workspaceNames: [], appCrowBinaryPath: secondPath)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: crowLink) == secondPath)
        #expect(FileManager.default.isExecutableFile(atPath: crowLink))
    }

    @Test func nonSymlinkCrowFileInBinDirIsLeftAlone() throws {
        let devRoot = try Self.makeTempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let binDir = (devRoot as NSString).appendingPathComponent(".claude/bin")
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let strangerFile = (binDir as NSString).appendingPathComponent("crow")
        try "user dropped this".write(toFile: strangerFile, atomically: true, encoding: .utf8)

        let toolsDir = (devRoot as NSString).appendingPathComponent("_tools")
        try FileManager.default.createDirectory(atPath: toolsDir, withIntermediateDirectories: true)
        let appCrowPath = try Self.makeExecutable(in: toolsDir, name: "crow-app")

        _ = try Scaffolder(devRoot: devRoot).scaffold(
            workspaceNames: [],
            appCrowBinaryPath: appCrowPath
        )

        let contents = try String(contentsOfFile: strangerFile, encoding: .utf8)
        #expect(contents == "user dropped this")
    }
}
