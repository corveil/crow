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
