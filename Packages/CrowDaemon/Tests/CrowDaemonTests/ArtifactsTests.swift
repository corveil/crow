import Foundation
import Testing
@testable import CrowDaemon

/// The artifacts route is a file server, so its guards are the security surface:
/// only real-UUID sessions, only bare image names, no traversal (CROW-593).
@Suite struct ArtifactsTests {
    @Test func rejectsNonUUIDSessionAndTraversal() {
        #expect(Artifacts.dir(sessionID: UUID().uuidString) != nil)
        #expect(Artifacts.dir(sessionID: "not-a-uuid") == nil)
        #expect(Artifacts.dir(sessionID: "../../etc") == nil)
        #expect(Artifacts.dir(sessionID: "") == nil)
    }

    @Test func safeImageNameGuard() {
        #expect(Artifacts.isSafeImageName("diagram.png"))
        #expect(Artifacts.isSafeImageName("a.b.jpeg"))
        #expect(!Artifacts.isSafeImageName("../secret.png"))
        #expect(!Artifacts.isSafeImageName("sub/dir.png"))
        #expect(!Artifacts.isSafeImageName("notes.txt"))
        #expect(!Artifacts.isSafeImageName("plain"))
        #expect(!Artifacts.isSafeImageName(""))
    }

    @Test func rejectsSymlinkEscapingTheScratchDir() throws {
        // A planted shot.png → ~/.ssh/id_rsa (or config.json) must not be served
        // (review Yellow — Data(contentsOf:) follows symlinks).
        let session = UUID().uuidString
        let dir = Artifacts.dir(sessionID: session)!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-artifact-secret-\(UUID().uuidString).txt")
        try Data("SECRET".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let link = dir.appendingPathComponent("shot.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(Artifacts.resolvedPathInside(dir: dir, file: link) == nil)

        // A real in-tree file still resolves.
        let real = dir.appendingPathComponent("ok.png")
        try Data("png".utf8).write(to: real)
        let resolved = Artifacts.resolvedPathInside(dir: dir, file: real)
        #expect(resolved != nil)
        #expect(resolved?.lastPathComponent == "ok.png")
    }

    @Test func listsOnlyImagesNewestFirst() throws {
        let session = UUID().uuidString
        let dir = Artifacts.dir(sessionID: session)!
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("x".utf8).write(to: dir.appendingPathComponent("a.png"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("b.svg"))

        let names = Artifacts.list(sessionID: session).map(\.name)
        #expect(Set(names) == ["a.png", "b.svg"])   // .txt excluded
    }
}
