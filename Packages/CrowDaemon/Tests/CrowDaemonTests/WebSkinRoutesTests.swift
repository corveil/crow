import CrowCore
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import CrowDaemon

/// CROW-1333: crowd serves the skin catalog and each skin's generated CSS from
/// the bundled `web/skins/*.json`, and both are reachable before sign-in so the
/// login page paints in the browser's chosen skin.
@Suite("Web skin routes")
struct WebSkinRoutesTests {
    private func makeApp(webDir: String? = nil) -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        StaticAssets.mount(on: router, webDir: webDir)
        return Application(router: router)
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable { let id: String; let name: String; let light: Bool }
        let `default`: String
        let skins: [Entry]
    }

    @Test func catalogListsTheBuiltInsWithCorveilFirst() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/skins.json", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-cache")
                let catalog = try JSONDecoder().decode(Catalog.self, from: Data(String(buffer: response.body).utf8))
                #expect(catalog.default == "corveil")
                #expect(catalog.skins.map(\.id) == ["corveil", "corveil-classic", "graphite"])
                #expect(catalog.skins.first { $0.id == "corveil-classic" }?.light == false)
                #expect(catalog.skins.first { $0.id == "graphite" }?.light == true)
            }
        }
    }

    @Test func skinCSSIsGeneratedAndScoped() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/skins/corveil-classic.css", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.hasPrefix("text/css") == true)
                let css = String(buffer: response.body)
                #expect(css.contains(":root[data-skin=\"corveil-classic\"]:not([data-theme=\"light\"]) {"))
                #expect(css.contains("--accent: #DDC482;"))
                #expect(!css.contains("[data-theme=\"light\"] {"), "Classic is dark only")
            }
        }
    }

    @Test("Unknown or malformed skin paths are refused", arguments: [
        "/skins/nope.css", "/skins/graphite.json", "/skins/..%2Ftheme.css", "/skins/Graphite.css",
    ])
    func unknownSkin(uri: String) async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: uri, method: .get) { response in
                #expect(response.status == .notFound || response.status == .badRequest, "\(uri)")
            }
        }
    }

    /// An invalid skin under `--web-dir` is skipped, not served: its CSS could
    /// break out of its declarations.
    @Test func invalidSkinFilesAreSkipped() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-skins-\(UUID().uuidString)")
        let skins = dir.appendingPathComponent("skins")
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(##"{"id":"good","name":"Good","dark":{"--accent":"#123456"}}"##.utf8)
            .write(to: skins.appendingPathComponent("good.json"))
        try Data(#"{"id":"evil","name":"Evil","dark":{"--accent":"red; } body { display: none"}}"#.utf8)
            .write(to: skins.appendingPathComponent("evil.json"))
        try Data(#"{"id":"other","name":"Misnamed","dark":{}}"#.utf8)
            .write(to: skins.appendingPathComponent("misnamed.json"))

        #expect(WebSkinCatalog.load(webDir: dir.path).map(\.id) == ["good"])
        try await makeApp(webDir: dir.path).test(.router) { client in
            try await client.execute(uri: "/skins/evil.css", method: .get) { response in
                #expect(response.status == .notFound)
            }
            try await client.execute(uri: "/skins/good.css", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func skinPathsAreAuthExemptAndNarrow() {
        typealias MW = WebAuthMiddleware<CrowHTTPContext>
        for path in ["/theme.js", "/skins.json", "/skins/graphite.css", "/skins/corveil-classic.css"] {
            #expect(MW.isAuthExempt(path: path), "\(path) must load on the login page")
        }
        for path in ["/skins/", "/skins/../app.js", "/skins/x.js", "/skins/A.css", "/skins/a/b.css"] {
            #expect(!MW.isAuthExempt(path: path), "\(path) must stay gated")
        }
    }
}
