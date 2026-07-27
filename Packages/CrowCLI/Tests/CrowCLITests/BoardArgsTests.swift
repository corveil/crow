import Foundation
import Testing
@testable import CrowCLILib

// MARK: - `crow batch-work-on-issues` URL-list assembly (CROW-817)

private func withTempFile(_ contents: String, _ body: (String) throws -> Void) throws {
    let path = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("crow-urls-\(UUID().uuidString).txt")
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    try body(path)
}

@Test func urlListReturnsInlineURLsUnchanged() throws {
    let urls = try BoardArgs.urlList(url: ["https://a/1", "https://b/2"], urlsFile: nil)
    #expect(urls == ["https://a/1", "https://b/2"])
}

@Test func urlListAppendsFileLinesAfterInlineURLs() throws {
    try withTempFile("https://c/3\nhttps://d/4\n") { path in
        let urls = try BoardArgs.urlList(url: ["https://a/1"], urlsFile: path)
        #expect(urls == ["https://a/1", "https://c/3", "https://d/4"])
    }
}

@Test func urlListDropsBlankLinesAndTrimsWhitespace() throws {
    // A trailing newline from a pipe must not become an empty URL the daemon
    // then has to report as rejected.
    try withTempFile("\n  https://c/3  \n\n\thttps://d/4\n\n") { path in
        let urls = try BoardArgs.urlList(url: [], urlsFile: path)
        #expect(urls == ["https://c/3", "https://d/4"])
    }
}

@Test func urlListKeepsDuplicates() throws {
    // The daemon dedupes while validating; stripping here would hide the
    // difference between what was asked for and the returned `sent` count.
    let urls = try BoardArgs.urlList(url: ["https://a/1", "https://a/1"], urlsFile: nil)
    #expect(urls == ["https://a/1", "https://a/1"])
}

@Test func urlListIsEmptyForAFileOfOnlyBlankLines() throws {
    try withTempFile("\n\n   \n") { path in
        let urls = try BoardArgs.urlList(url: [], urlsFile: path)
        #expect(urls.isEmpty)
    }
}

@Test func urlListThrowsOnMissingFile() {
    #expect(throws: (any Error).self) {
        _ = try BoardArgs.urlList(url: [], urlsFile: "/definitely/not/here.txt")
    }
}
