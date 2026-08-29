import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CrowDaemon

/// The daemon must serve its own HTML/JS/CSS with revalidation headers so an
/// already-open browser tab picks up a new build on a normal reload instead of
/// running a stale, heuristically cached `app.js` (CROW-1024). A strong ETag
/// keeps that revalidation cheap by letting an unchanged asset answer with an
/// empty 304. The `/xterm/*` vendor bundle deliberately keeps its long-lived
/// cache and stays out of this policy.
@Suite("Static asset cache policy")
struct StaticAssetsCacheTests {

    /// A router with just the static-asset routes mounted; assets resolve from the
    /// compiled `Bundle.module` (`webDir` nil). No middleware and no actor state,
    /// so `.test(.router)` is enough.
    private func makeApp() -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        StaticAssets.mount(on: router)
        return Application(router: router)
    }

    @Test("Every UI JS file is served with Cache-Control: no-cache and a strong ETag",
          arguments: StaticAssets.uiJavaScriptFiles)
    func uiJSRevalidates(file: String) async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/\(file)", method: .get) { response in
                #expect(response.status == .ok, "\(file) should be served")
                #expect(response.headers[.cacheControl] == "no-cache", "\(file) must revalidate (CROW-1024)")
                let etag = try #require(response.headers[.eTag])
                // A strong validator: quoted, and more than just the empty quotes.
                #expect(etag.hasPrefix("\"") && etag.hasSuffix("\""))
                #expect(etag.count > 2)
                #expect(response.body.readableBytes > 0)
            }
        }
    }

    @Test("A conditional GET with the current ETag returns an empty 304")
    func conditionalGETReturns304() async throws {
        try await makeApp().test(.router) { client in
            // Learn the ETag the server is currently advertising for app.js.
            let etag = try await client.execute(uri: "/app.js", method: .get) { response in
                #expect(response.status == .ok)
                return try #require(response.headers[.eTag])
            }
            // Re-request it conditionally → 304 Not Modified with no body, but the
            // validating headers are still present.
            try await client.execute(
                uri: "/app.js", method: .get, headers: [.ifNoneMatch: etag]
            ) { response in
                #expect(response.status == .notModified)
                #expect(response.body.readableBytes == 0)
                #expect(response.headers[.eTag] == etag)
                #expect(response.headers[.cacheControl] == "no-cache")
            }
        }
    }

    @Test("A stale If-None-Match still gets the full 200 body")
    func staleETagGetsFullBody() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(
                uri: "/app.js", method: .get, headers: [.ifNoneMatch: "\"not-the-current-etag\""]
            ) { response in
                #expect(response.status == .ok)
                #expect(response.body.readableBytes > 0)
                #expect(response.headers[.eTag] != nil)
            }
        }
    }

    @Test("index.html loads every UI JS file in StaticAssets.uiJavaScriptFiles order")
    func indexHTMLScriptOrderMatchesTheRouteTable() throws {
        // Walk up to Resources/web/index.html — same lookup as WebTerminalAssetTests.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(
                "Sources/CrowDaemon/Resources/web/index.html")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let html = try String(contentsOf: try #require(found), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"<script src="/([^"]+\.js)"></script>"#)
        let ns = html as NSString
        var names: [String] = []
        pattern.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let name = ns.substring(with: match.range(at: 1))
            if !name.hasPrefix("xterm/") { names.append(name) }
        }
        #expect(names == StaticAssets.uiJavaScriptFiles,
                "index.html script order must match the StaticAssets route table (CROW-1155)")
    }

    @Test("index.html keeps its CSP alongside the new cache headers")
    func indexHTMLKeepsCSPAndCaching() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-cache")
                #expect(response.headers[.eTag] != nil)
                #expect(response.headers[.contentSecurityPolicy] != nil)
            }
        }
    }

    @Test("The xterm vendor bundle stays out of the revalidation policy")
    func xtermIsNotRevalidated() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/xterm/xterm.js", method: .get) { response in
                // It is served (from CrowTerminal's bundle); the point is that it
                // carries neither the no-cache directive nor an ETag, so the long-
                // lived vendor cache is untouched (CROW-1024).
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == nil)
                #expect(response.headers[.eTag] == nil)
            }
        }
    }

    // MARK: - Web app manifest + install icons (CROW-1073)

    @Test("The web app manifest is served with the manifest+json content type")
    func manifestServedWithCorrectContentType() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/manifest.webmanifest", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.body.readableBytes > 0)
                let ct = try #require(response.headers[.contentType])
                #expect(ct == "application/manifest+json")
            }
        }
    }

    @Test("The install icons are served as image/png")
    func installIconsServedAsPNG() async throws {
        try await makeApp().test(.router) { client in
            for path in ["/icon-192.png", "/icon-512.png", "/apple-touch-icon.png"] {
                try await client.execute(uri: path, method: .get) { response in
                    #expect(response.status == .ok, "\(path) should be served")
                    #expect(response.body.readableBytes > 0, "\(path) should have a body")
                    #expect(response.headers[.contentType] == "image/png", "\(path) content type")
                }
            }
        }
    }
}
