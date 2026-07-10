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

    // MARK: - Upload helpers (#644 images, #652 any file)

    @Test func uploadExtensionPrefersFilenameThenContentType() {
        // The filename's own extension wins whenever it's a plausible extension.
        #expect(Artifacts.uploadExtension(contentType: "image/png", filename: "shot.PNG") == "png")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "a.jpeg") == "jpeg")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "b.gif") == "gif")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "c.webp") == "webp")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "data.tar.gz") == "gz")
        // Filename wins over a mismatched Content-Type guess (store what the user
        // dropped, not the browser's sniff): notes.txt stays `.txt`.
        #expect(Artifacts.uploadExtension(contentType: "image/jpeg; charset=binary", filename: "notes.txt") == "txt")
        // Falls back to the Content-Type image map when the filename has no usable
        // extension (params stripped) — recovers a pasted screenshot's type.
        #expect(Artifacts.uploadExtension(contentType: "image/png", filename: nil) == "png")
        #expect(Artifacts.uploadExtension(contentType: "image/jpeg; charset=binary", filename: nil) == "jpg")
    }

    @Test func uploadExtensionAcceptsAnyFile() {
        // #652 lifted the raster-only gate: ordinary files keep their extension.
        #expect(Artifacts.uploadExtension(contentType: "image/svg+xml", filename: "logo.svg") == "svg")
        #expect(Artifacts.uploadExtension(contentType: "application/pdf", filename: "doc.pdf") == "pdf")
        #expect(Artifacts.uploadExtension(contentType: "text/plain", filename: "notes.txt") == "txt")
        #expect(Artifacts.uploadExtension(contentType: "application/zip", filename: "archive.zip") == "zip")
        // Extensionless files (Makefile, LICENSE) → no extension, still accepted.
        #expect(Artifacts.uploadExtension(contentType: "text/plain", filename: "Makefile") == "")
        #expect(Artifacts.uploadExtension(contentType: nil, filename: nil) == "")
        // A metacharacter-bearing "extension" is rejected as unsafe, then the
        // Content-Type map (nil here) yields no extension — never a bad name.
        #expect(Artifacts.uploadExtension(contentType: nil, filename: "weird.p<n>g") == "")
    }

    @Test func isSafeExtensionGuard() {
        #expect(Artifacts.isSafeExtension("png"))
        #expect(Artifacts.isSafeExtension("tar"))
        #expect(Artifacts.isSafeExtension("mp4"))
        #expect(!Artifacts.isSafeExtension(""))              // no extension
        #expect(!Artifacts.isSafeExtension("p n g"))         // whitespace
        #expect(!Artifacts.isSafeExtension("sh/x"))          // separator
        #expect(!Artifacts.isSafeExtension(".."))            // traversal
        #expect(!Artifacts.isSafeExtension(String(repeating: "a", count: 17))) // too long
    }

    @Test func isSafeUploadNameGuard() {
        // The write-side gate accepts any bare name (no image-ext requirement).
        #expect(Artifacts.isSafeUploadName("drop-abcd1234-notes.txt"))
        #expect(Artifacts.isSafeUploadName("drop-abcd1234-archive.zip"))
        #expect(Artifacts.isSafeUploadName("drop-abcd1234-Makefile"))  // no extension
        #expect(!Artifacts.isSafeUploadName("../secret"))
        #expect(!Artifacts.isSafeUploadName("sub/dir.txt"))
        #expect(!Artifacts.isSafeUploadName(""))
    }

    @Test func sanitizedUploadNameIsSafeUniqueAndTraversalProof() {
        // Spaces/metachars stripped from the stem; result is always a safe name.
        let a = Artifacts.sanitizedUploadName(filename: "my shot!.png", ext: "png")
        #expect(a.hasPrefix("drop-"))
        #expect(a.hasSuffix(".png"))
        #expect(Artifacts.isSafeImageName(a))
        #expect(!a.contains(" "))

        // A non-image file keeps its extension and is a safe upload name (but not
        // an image name, so the serve route won't hand it back).
        let doc = Artifacts.sanitizedUploadName(filename: "quarterly report.pdf", ext: "pdf")
        #expect(doc.hasSuffix(".pdf"))
        #expect(Artifacts.isSafeUploadName(doc))
        #expect(!Artifacts.isSafeImageName(doc))
        #expect(!doc.contains(" "))

        // A traversal-y name collapses to its bare component and stays safe.
        let b = Artifacts.sanitizedUploadName(filename: "../../etc/passwd", ext: "png")
        #expect(Artifacts.isSafeImageName(b))
        #expect(!b.contains("/"))
        #expect(!b.contains(".."))

        // Empty/nil stem defaults to "file".
        #expect(Artifacts.sanitizedUploadName(filename: nil, ext: "gif").contains("-file.gif"))

        // No/empty extension → no trailing dot, still a safe upload name.
        let noExt = Artifacts.sanitizedUploadName(filename: "Makefile", ext: "")
        #expect(noExt.hasPrefix("drop-"))
        #expect(!noExt.hasSuffix("."))
        #expect(noExt.hasSuffix("-Makefile"))
        #expect(Artifacts.isSafeUploadName(noExt))

        // An unsafe extension is dropped rather than injected into the name.
        let bad = Artifacts.sanitizedUploadName(filename: "x", ext: "../sh")
        #expect(!bad.contains("/"))
        #expect(!bad.contains(".."))
        #expect(Artifacts.isSafeUploadName(bad))

        // Unique token → repeated drops of the same file don't collide.
        let c = Artifacts.sanitizedUploadName(filename: "x.png", ext: "png")
        let d = Artifacts.sanitizedUploadName(filename: "x.png", ext: "png")
        #expect(c != d)
    }
}
