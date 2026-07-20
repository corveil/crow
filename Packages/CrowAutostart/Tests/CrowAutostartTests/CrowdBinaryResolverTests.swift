import Testing
import Foundation
@testable import CrowAutostart

private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crow-resolver-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func makeExecutable(_ url: URL) throws -> String {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
}

@Test func resolverPrefersAnExplicitOverride() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let override = try makeExecutable(root.appendingPathComponent("custom/crowd"))
    let sibling = root.appendingPathComponent("bin/crow")
    try makeExecutable(sibling)
    try makeExecutable(root.appendingPathComponent("bin/crowd"))

    let resolved = try CrowdBinaryResolver.resolve(override: override, siblingOf: sibling, pathEnvironment: nil)

    #expect(resolved == override)
}

/// `make install` symlinks `crow` and `crowd` into the same directory, so the
/// sibling of the running CLI is the right default.
@Test func resolverFindsCrowdNextToTheCallingExecutable() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sibling = root.appendingPathComponent("bin/crow")
    try makeExecutable(sibling)
    let crowd = try makeExecutable(root.appendingPathComponent("bin/crowd"))

    let resolved = try CrowdBinaryResolver.resolve(siblingOf: sibling, pathEnvironment: nil)

    #expect(resolved == crowd)
}

@Test func resolverFallsBackToPATH() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let crowd = try makeExecutable(root.appendingPathComponent("path-dir/crowd"))

    let resolved = try CrowdBinaryResolver.resolve(
        siblingOf: root.appendingPathComponent("elsewhere/crow"),
        pathEnvironment: root.appendingPathComponent("path-dir").path)

    #expect(resolved == crowd)
}

/// The plist must point at the symlink `make install` created, not its target —
/// the symlink survives rebuilds and debug/release switches.
@Test func resolverDoesNotResolveSymlinks() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let real = try makeExecutable(root.appendingPathComponent("build/crowd"))
    let binDir = root.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let link = binDir.appendingPathComponent("crowd")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real)

    let resolved = try CrowdBinaryResolver.resolve(siblingOf: binDir.appendingPathComponent("crow"),
                                                  pathEnvironment: nil)

    #expect(resolved == link.path)
}

@Test func resolverRejectsANonExecutableOverride() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = root.appendingPathComponent("crowd")
    try Data("not executable".utf8).write(to: plain)

    #expect(throws: AutostartError.self) {
        _ = try CrowdBinaryResolver.resolve(override: plain.path, siblingOf: nil, pathEnvironment: nil)
    }
}

/// A *directory* named `crowd` reports as "executable" (that's the search bit),
/// so the resolver has to check the file type too.
@Test func resolverIgnoresADirectoryNamedCrowd() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("bin/crowd"),
                                            withIntermediateDirectories: true)

    #expect(throws: AutostartError.self) {
        _ = try CrowdBinaryResolver.resolve(siblingOf: root.appendingPathComponent("bin/crow"),
                                            pathEnvironment: nil)
    }
}

@Test func resolverErrorPointsAtMakeInstall() throws {
    let root = try makeTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    do {
        _ = try CrowdBinaryResolver.resolve(siblingOf: root.appendingPathComponent("bin/crow"),
                                            pathEnvironment: "")
        Issue.record("expected the resolver to throw")
    } catch let error as AutostartError {
        #expect(error.errorDescription?.contains("make install") == true)
    }
}

@Test func unsupportedPlatformReportsCleanlyInsteadOfFailing() throws {
    let service = UnsupportedAutostart(platform: "linux")

    let status = try service.status(expected: AutostartSpec(binaryPath: "/usr/bin/crowd"))

    #expect(!status.supported)
    #expect(!status.enabled)
    #expect(status.platform == "linux")
    #expect(status.message.contains("645"))
    #expect(throws: AutostartError.self) {
        _ = try service.install(AutostartSpec(binaryPath: "/usr/bin/crowd"))
    }
}
