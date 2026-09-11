import Foundation
import Testing
@testable import CrowEngine

@Suite("Corveil auto-update helpers")
struct CorveilAutoUpdateTests {
    @Test func maxAssetBytesFitsPublishedCLIs() {
        // v0.4.41 darwin-amd64 is 111_143_664 bytes; all four platform binaries
        // sit just over 100 MiB. An 80 MiB cap rejected every published asset.
        #expect(CorveilAutoUpdate.maxAssetBytes >= 200 * 1024 * 1024)
    }

    @Test func assetNameMapsX86ToAmd64() {
        #expect(CorveilAutoUpdate.assetName(os: "darwin", arch: "arm64") == "corveil-darwin-arm64")
        #expect(CorveilAutoUpdate.assetName(os: "linux", arch: "x86_64") == "corveil-linux-amd64")
        #expect(CorveilAutoUpdate.assetName(os: "linux", arch: "amd64") == "corveil-linux-amd64")
    }

    @Test func shouldAutoManageWhenPathUnsetOrManaged() {
        let root = URL(fileURLWithPath: "/tmp/crow-managed-corveil")
        #expect(CorveilAutoUpdate.shouldAutoManage(configuredPath: nil, managedRoot: root))
        #expect(CorveilAutoUpdate.shouldAutoManage(configuredPath: "  ", managedRoot: root))
        #expect(CorveilAutoUpdate.shouldAutoManage(
            configuredPath: "/tmp/crow-managed-corveil/v0.4.32/corveil", managedRoot: root))
        #expect(!CorveilAutoUpdate.shouldAutoManage(
            configuredPath: "/Users/jane/dev/corveil/out/corveil-darwin-arm64", managedRoot: root))
    }

    @Test func parseChecksumsAcceptsGnuSha256sum() {
        let text = """
        # ignore
        abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789  corveil-darwin-arm64
        1111111111111111111111111111111111111111111111111111111111111111 *corveil-linux-amd64
        not-a-hash  skip-me
        """
        let table = CorveilAutoUpdate.parseChecksums(text)
        #expect(table["corveil-darwin-arm64"] ==
                "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        #expect(table["corveil-linux-amd64"] ==
                "1111111111111111111111111111111111111111111111111111111111111111")
        #expect(table["skip-me"] == nil)
    }

    @Test func verifyMessageRequiresVersionTokenNotPrefix() {
        #expect(CorveilAutoUpdate.verifyMessage("corveil 0.4.32", matchesTag: "v0.4.32"))
        #expect(CorveilAutoUpdate.verifyMessage("corveil version 0.4.32 (darwin/arm64)", matchesTag: "0.4.32"))
        #expect(!CorveilAutoUpdate.verifyMessage("corveil 0.4.3", matchesTag: "v0.4.32"))
        #expect(!CorveilAutoUpdate.verifyMessage("corveil 0.4.320", matchesTag: "v0.4.32"))
    }

    @Test func pruneOldVersionsKeepsCurrentAndOnePrevious() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1210-prune-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func touch(_ tag: String, age: TimeInterval) throws {
            let dir = root.appendingPathComponent(tag, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: dir.appendingPathComponent("corveil"))
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(age)],
                ofItemAtPath: dir.path)
        }
        try touch("v0.4.30", age: -300)
        try touch("v0.4.31", age: -200)
        try touch("v0.4.32", age: -10)

        CorveilAutoUpdate.pruneOldVersions(keeping: "v0.4.32", managedRoot: root)

        let left = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(left.contains("v0.4.32"))
        #expect(left.contains("v0.4.31"))
        #expect(!left.contains("v0.4.30"))
    }
}

@Suite("Corveil release client")
struct CorveilReleaseClientTests {
    @Test func fetchLatestParsesTagAndAssets() async throws {
        let payload: [String: Any] = [
            "tag_name": "v0.4.32",
            "assets": [
                [
                    "name": "corveil-darwin-arm64",
                    "browser_download_url": "https://example.test/corveil-darwin-arm64",
                    "size": 12,
                ],
                [
                    "name": "checksums.txt",
                    "browser_download_url": "https://example.test/checksums.txt",
                    "size": 80,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            #expect(request.url?.absoluteString.contains("/releases/latest") == true)
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let release = try await CorveilReleaseClient.fetchRelease(
            version: "latest", userAgent: "Crow/test", transport: transport)
        #expect(release.tag == "v0.4.32")
        #expect(release.asset(named: "corveil-darwin-arm64")?.size == 12)
        #expect(release.asset(named: "checksums.txt") != nil)
    }

    @Test func fetchPinnedTagHitsTagsEndpoint() async throws {
        let payload: [String: Any] = ["tag_name": "v0.4.31", "assets": []]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            #expect(request.url?.absoluteString.contains("/releases/tags/v0.4.31") == true)
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let release = try await CorveilReleaseClient.fetchRelease(
            version: "v0.4.31", userAgent: "Crow/test", transport: transport)
        #expect(release.tag == "v0.4.31")
    }

    @Test func fetchMapsHttp404() async {
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            (Data(), HTTPURLResponse(
                url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: CorveilReleaseClient.FetchError.self) {
            _ = try await CorveilReleaseClient.fetchRelease(
                version: "v9.9.9", userAgent: "Crow/test", transport: transport)
        }
    }

    @Test func downloadRejectsOversizedPayload() async {
        let blob = Data(repeating: 1, count: 16)
        let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            (blob, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: CorveilReleaseClient.FetchError.self) {
            _ = try await CorveilReleaseClient.download(
                url: URL(string: "https://example.test/bin")!,
                userAgent: "Crow/test",
                maxBytes: 8,
                transport: transport)
        }
    }
}
