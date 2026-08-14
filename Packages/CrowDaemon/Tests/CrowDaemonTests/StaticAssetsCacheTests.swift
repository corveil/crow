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

    @Test("app.js is served with Cache-Control: no-cache and a strong ETag")
    func appJSRevalidates() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/app.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-cache")
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
}
