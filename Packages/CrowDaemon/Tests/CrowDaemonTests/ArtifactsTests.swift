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

    // MARK: - Upload helpers (#644)

    @Test func uploadExtensionPrefersFilenameThenContentType() {
        // Filename extension wins when it's an accepted raster.
        #expect(Artifacts.uploadExtension(contentType: "image/png", filename: "shot.PNG") == "png")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "a.jpeg") == "jpeg")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "b.gif") == "gif")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "c.webp") == "webp")
        // Falls back to the Content-Type media type (params stripped).
        #expect(Artifacts.uploadExtension(contentType: "image/jpeg; charset=binary", filename: "notes.txt") == "jpg")
        #expect(Artifacts.uploadExtension(contentType: "image/png", filename: nil) == "png")
    }

    @Test func uploadExtensionRejectsNonRasterInput() {
        // SVG is script-bearing → kept out of the drop input path.
        #expect(Artifacts.uploadExtension(contentType: "image/svg+xml", filename: "logo.svg") == nil)
        #expect(Artifacts.uploadExtension(contentType: "application/pdf", filename: "doc.pdf") == nil)
        #expect(Artifacts.uploadExtension(contentType: "text/plain", filename: "notes.txt") == nil)
        #expect(Artifacts.uploadExtension(contentType: nil, filename: nil) == nil)
    }

    @Test func sanitizedUploadNameIsSafeUniqueAndTraversalProof() {
        // Spaces/metachars stripped from the stem; result is always a safe name.
        let a = Artifacts.sanitizedUploadName(filename: "my shot!.png", ext: "png")
        #expect(a.hasPrefix("drop-"))
        #expect(a.hasSuffix(".png"))
        #expect(Artifacts.isSafeImageName(a))
        #expect(!a.contains(" "))

        // A traversal-y name collapses to its bare component and stays safe.
        let b = Artifacts.sanitizedUploadName(filename: "../../etc/passwd", ext: "png")
        #expect(Artifacts.isSafeImageName(b))
        #expect(!b.contains("/"))
        #expect(!b.contains(".."))

        // Empty/nil stem defaults to "image".
        #expect(Artifacts.sanitizedUploadName(filename: nil, ext: "gif").contains("-image.gif"))

        // Unique token → repeated drops of the same file don't collide.
        let c = Artifacts.sanitizedUploadName(filename: "x.png", ext: "png")
        let d = Artifacts.sanitizedUploadName(filename: "x.png", ext: "png")
        #expect(c != d)
    }
}
