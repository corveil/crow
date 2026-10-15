import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import CrowEngine
@testable import CrowDaemon

/// CROW-1334: the `skin-*` RPCs behind `crow skin`, and the custom skins and
/// daemon-wide default they surface through `/skins.json` — against a temp
/// skin store and a temp dev root, never the user's.
@Suite struct SkinRPCTests {
    private struct Env {
        let devRoot: String
        let store: WebSkinStore
        var sources: WebSkinSources { WebSkinSources(store: store, devRoot: devRoot) }

        func cleanup() {
            try? FileManager.default.removeItem(atPath: devRoot)
            try? FileManager.default.removeItem(at: store.directory)
        }
    }

    private func env() -> Env {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-skins-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return Env(devRoot: dir, store: .temporary())
    }

    @MainActor
    private func call(_ method: String, _ params: [String: JSONValue] = [:], env: Env) async -> JSONRPCResponse {
        await makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: env.devRoot, cockpit: nil, skinSources: env.sources)
            .handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    private func ids(_ resp: JSONRPCResponse) -> [String] {
        (resp.result?["skins"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
    }

    // MARK: - list / get

    @Test @MainActor func listShowsBuiltInsWithModesAndTheDefault() async {
        let env = env()
        defer { env.cleanup() }
        let resp = await call("skin-list", env: env)
        #expect(ids(resp) == ["corveil", "corveil-classic", "graphite"])
        #expect(resp.result?["default"] == .string("corveil"))
        let classic = resp.result?["skins"]?.arrayValue?[1].objectValue
        #expect(classic?["builtin"] == .bool(true))
        #expect(classic?["modes"] == .array([.string("dark")]))
    }

    @Test @MainActor func getResolvesEveryToken() async throws {
        let env = env()
        defer { env.cleanup() }
        let resp = await call("skin-get", ["id": .string("corveil")], env: env)
        let skin = try #require(resp.result?["skin"]?.objectValue)
        #expect(skin["dark"]?.objectValue?.count == WebSkin.tokens.count)
        #expect(resp.result?["warnings"] == .array([]))
        #expect(await call("skin-get", ["id": .string("nope")], env: env).error != nil)
    }

    // MARK: - create

    /// Ticket acceptance: the example command makes a skin that is listed and served.
    @Test @MainActor func createFromClassicWithAnAccent() async throws {
        let env = env()
        defer { env.cleanup() }
        let resp = await call("skin-create", [
            "from": .string("corveil-classic"), "name": .string("Dusty"),
            "set": .object(["accent": .string("#7AA2F7")]),
        ], env: env)
        #expect(resp.error == nil, "\(String(describing: resp.error))")
        #expect(resp.result?["saved"] == .bool(true))
        let stored = try #require(env.store.skin(id: "dusty"))
        #expect(stored.dark["--accent"] == "#7AA2F7")
        #expect(stored.dark["--bg-deep"] == "#121416", "the rest comes from Classic")
        #expect(!stored.supportsLight)

        let list = await call("skin-list", env: env)
        #expect(ids(list).contains("dusty"))
        #expect(WebSkinCatalog.skin(id: "dusty", sources: env.sources)?.builtin == false)
    }

    @Test @MainActor func createRejectsBadValuesAndBuiltInIDs() async {
        let env = env()
        defer { env.cleanup() }
        let badColor = await call("skin-create", [
            "from": .string("corveil"), "name": .string("X"),
            "set": .object(["accent": .string("12px")]),
        ], env: env)
        #expect(badColor.error?.message.contains("--accent must be a color") == true)
        let termVar = await call("skin-create", [
            "from": .string("corveil"), "name": .string("Y"),
            "set": .object(["term-bg": .string("var(--bg-deep)")]),
        ], env: env)
        #expect(termVar.error?.message.contains("--term-bg must be a literal") == true)
        let shadow = await call("skin-create", [
            "from": .string("corveil"), "name": .string("Graphite"),
        ], env: env)
        #expect(shadow.error?.message.contains("built-in") == true)
        #expect(env.store.skins().isEmpty)
    }

    @Test @MainActor func createReportsContrastWarningsButSaves() async throws {
        let env = env()
        defer { env.cleanup() }
        let resp = await call("skin-create", [
            "from": .string("corveil"), "name": .string("Murky"),
            "set": .object(["text-muted": .string("#333333"), "bg-deep": .string("#000000")]),
        ], env: env)
        #expect(resp.result?["saved"] == .bool(true))
        let warnings = try #require(resp.result?["warnings"]?.arrayValue)
        let muted = try #require(warnings.compactMap(\.objectValue).first {
            $0["foreground"] == .string("--text-muted") && $0["background"] == .string("--bg-deep")
        })
        #expect(muted["ratio"] == .double(1.66))
        #expect(muted["minimum"] == .double(4.5))
        #expect(env.store.skin(id: "murky") != nil)
    }

    // MARK: - add

    @Test @MainActor func addValidatesAndCopies() async throws {
        let env = env()
        defer { env.cleanup() }
        let file = URL(fileURLWithPath: env.devRoot).appendingPathComponent("dusk.json")
        try Data(##"{"id":"dusk","name":"Dusk","dark":{"--accent":"#7AA2F7"}}"##.utf8).write(to: file)
        let ok = await call("skin-add", ["path": .string(file.path), "id": .string("dusk-2")], env: env)
        #expect(ok.error == nil)
        #expect(env.store.skin(id: "dusk-2")?.name == "Dusk")

        try Data(#"{"name":"No Id","dark":{}}"#.utf8).write(to: file)
        let malformed = await call("skin-add", ["path": .string(file.path)], env: env)
        #expect(malformed.error?.message == "Not a skin file: missing required key \"id\"")

        let relative = await call("skin-add", ["path": .string("dusk.json")], env: env)
        #expect(relative.error?.message.contains("absolute") == true)
    }

    @Test func addIsLocalOnly() {
        #expect(ParityLedger.localOnlyRPCMethods.contains("skin-add"))
        #expect(!ParityLedger.localOnlyRPCMethods.contains("skin-create"))
    }

    // MARK: - remove / default

    @Test @MainActor func removeRefusesBuiltInsAndClearsAMatchingDefault() async throws {
        let env = env()
        defer { env.cleanup() }
        let builtin = await call("skin-remove", ["id": .string("graphite")], env: env)
        #expect(builtin.error?.message.contains("built-in") == true)

        try env.store.save(WebSkin(id: "dusty", name: "Dusty", dark: ["--accent": "#7AA2F7"]))
        #expect(await call("skin-default-set", ["id": .string("dusty")], env: env).error == nil)
        #expect(ConfigStore.loadConfig(devRoot: env.devRoot)?.webDefaultSkin == "dusty")
        #expect(await call("skin-list", env: env).result?["default"] == .string("dusty"))

        let removed = await call("skin-remove", ["id": .string("dusty")], env: env)
        #expect(removed.result?["default_cleared"] == .bool(true))
        #expect(ConfigStore.loadConfig(devRoot: env.devRoot)?.webDefaultSkin == nil)
        #expect(await call("skin-remove", ["id": .string("dusty")], env: env).error != nil)
    }

    @Test @MainActor func defaultSetRequiresAListedSkinAndClearResets() async {
        let env = env()
        defer { env.cleanup() }
        #expect(await call("skin-default-set", ["id": .string("nope")], env: env).error != nil)
        #expect(await call("skin-default-set", ["id": .string("graphite")], env: env).error == nil)
        #expect(ConfigStore.loadConfig(devRoot: env.devRoot)?.webDefaultSkin == "graphite")
        #expect(await call("skin-default-clear", env: env).result?["default"] == .string("corveil"))
        #expect(ConfigStore.loadConfig(devRoot: env.devRoot)?.webDefaultSkin == nil)
    }

    // MARK: - What browsers see

    private struct Catalog: Decodable {
        struct Entry: Decodable { let id: String; let builtin: Bool }
        let `default`: String
        let revision: String
        let skins: [Entry]
    }

    private func catalog(_ sources: WebSkinSources) throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: WebSkinCatalog.catalogJSON(sources))
    }

    /// A custom skin is listed and served; one whose id is a built-in's is not;
    /// and every change moves `revision`, which is what open tabs poll.
    @Test func catalogMergesCustomSkinsAndMovesItsRevision() async throws {
        let env = env()
        defer { env.cleanup() }
        let before = try catalog(env.sources)

        try env.store.save(WebSkin(id: "dusty", name: "Dusty", dark: ["--accent": "#7AA2F7"]))
        try Data(#"{"id":"graphite","name":"Fake Graphite","dark":{}}"#.utf8)
            .write(to: env.store.fileURL(id: "graphite"))
        let added = try catalog(env.sources)
        #expect(added.skins.map(\.id) == ["corveil", "corveil-classic", "dusty", "graphite"])
        #expect(added.skins.first { $0.id == "dusty" }?.builtin == false)
        #expect(added.skins.first { $0.id == "graphite" }?.builtin == true, "built-ins can't be shadowed")
        #expect(added.revision != before.revision)

        var config = AppConfig()
        config.webDefaultSkin = "dusty"
        try ConfigStore.saveConfig(config, devRoot: env.devRoot)
        let defaulted = try catalog(env.sources)
        #expect(defaulted.default == "dusty")
        #expect(defaulted.revision != added.revision)

        try env.store.remove(id: "dusty")
        let removed = try catalog(env.sources)
        #expect(removed.default == "corveil", "a default that no longer exists falls back")

        let router = Router(context: CrowHTTPContext.self)
        StaticAssets.mount(on: router, skins: env.sources)
        try env.store.save(WebSkin(id: "dusk", name: "Dusk", dark: ["--accent": "#123456"]))
        try await Application(router: router).test(.router) { client in
            try await client.execute(uri: "/skins/dusk.css", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("--accent: #123456;"))
            }
        }
    }
}
