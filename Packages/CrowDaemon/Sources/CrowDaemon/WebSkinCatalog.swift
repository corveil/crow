import CrowCore
import CrowPersistence
import Crypto
import Foundation

/// Where `crowd` finds skins (CROW-1334): the built-ins under `--web-dir` or
/// the daemon bundle, the operator's custom skin store, and the dev root whose
/// `config.json` names the daemon-wide default.
///
/// `store`/`devRoot` are optional so a route test can serve the built-ins
/// alone without touching the user's Application Support or config.
struct WebSkinSources: Sendable {
    var webDir: String?
    var store: WebSkinStore?
    var devRoot: String?

    init(webDir: String? = nil, store: WebSkinStore? = nil, devRoot: String? = nil) {
        self.webDir = webDir
        self.store = store
        self.devRoot = devRoot
    }
}

/// The skins `crowd` serves to the web UI (CROW-1333): every valid
/// `web/skins/*.json`, read from `--web-dir` when set (edit + refresh, like the
/// rest of the UI) and from the daemon bundle otherwise — plus, since CROW-1334,
/// the operator's custom skins from ``WebSkinStore``.
///
/// Read per request. There are a handful of small files, and reading them live
/// keeps `--web-dir` honest — and makes `crow skin add`/`remove` live — without
/// a cache to invalidate.
enum WebSkinCatalog {
    /// One skin as listed, with where it came from.
    struct Listed: Sendable {
        let skin: WebSkin
        let builtin: Bool
    }

    /// Valid built-in skins, the default (Corveil) first and the rest by name.
    /// An invalid file is skipped rather than served: its CSS could not be
    /// trusted to stay inside its declarations.
    static func load(webDir: String?) -> [WebSkin] {
        var byID: [String: WebSkin] = [:]
        for url in skinFiles(webDir: webDir) {
            guard let data = try? Data(contentsOf: url),
                  let skin = try? JSONDecoder().decode(WebSkin.self, from: data),
                  url.deletingPathExtension().lastPathComponent == skin.id else { continue }
            let errors = skin.validationErrors()
            if !errors.isEmpty {
                CrowLog.info("[crowd] web skin \(url.lastPathComponent) skipped: \(errors.map(\.description).joined(separator: "; "))")
                continue
            }
            byID[skin.id] = skin
        }
        return sorted(Array(byID.values))
    }

    /// Built-ins, then usable custom skins. A custom skin whose id is a
    /// built-in's is skipped: built-ins cannot be shadowed. Corveil first,
    /// the rest by name.
    static func listing(_ sources: WebSkinSources) -> [Listed] {
        let builtins = load(webDir: sources.webDir)
        let builtinIDs = Set(builtins.map(\.id))
        let custom = (sources.store?.skins() ?? []).filter { !builtinIDs.contains($0.id) }
        let customIDs = Set(custom.map(\.id))
        return sorted(builtins + custom).map { Listed(skin: $0, builtin: !customIDs.contains($0.id)) }
    }

    static func builtinIDs(webDir: String?) -> Set<String> {
        Set(load(webDir: webDir).map(\.id))
    }

    static func skin(id: String, sources: WebSkinSources) -> Listed? {
        guard WebSkin.isValidID(id) else { return nil }
        return listing(sources).first { $0.skin.id == id }
    }

    /// The daemon-wide default: `webDefaultSkin` from config when it names a
    /// skin that is still listed, otherwise Corveil. A removed default falls
    /// back rather than leaving browsers on a skin that no longer exists.
    static func defaultID(_ sources: WebSkinSources, listed: [Listed]) -> String {
        guard let devRoot = sources.devRoot,
              let configured = ConfigStore.loadConfig(devRoot: devRoot)?.webDefaultSkin,
              listed.contains(where: { $0.skin.id == configured }) else { return WebSkin.defaultID }
        return configured
    }

    /// `GET /skins.json`: what the Settings picker lists and what `theme.js`
    /// needs before it asks for CSS (whether a skin has a light mode), the
    /// default for a browser that has not chosen, and a `revision` that
    /// changes whenever any of that or any skin's CSS does — `theme.js` polls
    /// it so an added, edited or removed skin reaches open tabs (CROW-1334).
    static func catalogJSON(_ sources: WebSkinSources) -> Data {
        struct Entry: Encodable {
            let id: String
            let name: String
            let light: Bool
            let builtin: Bool
        }
        struct Catalog: Encodable {
            let defaultSkin: String
            let revision: String
            let skins: [Entry]
            enum CodingKeys: String, CodingKey {
                case defaultSkin = "default"
                case revision, skins
            }
        }
        let listed = listing(sources)
        let defaultSkin = defaultID(sources, listed: listed)
        let catalog = Catalog(
            defaultSkin: defaultSkin,
            revision: revision(listed, defaultSkin: defaultSkin),
            skins: listed.map {
                Entry(id: $0.skin.id, name: $0.skin.name, light: $0.skin.supportsLight, builtin: $0.builtin)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(catalog))
            ?? Data("{\"default\":\"corveil\",\"revision\":\"\",\"skins\":[]}".utf8)
    }

    /// A short digest of everything the catalog and the CSS routes serve.
    static func revision(_ listed: [Listed], defaultSkin: String) -> String {
        var text = "default=\(defaultSkin)\n"
        for entry in listed {
            text += "\(entry.skin.id)|\(entry.skin.name)|\(entry.builtin)\n\(entry.skin.css())\n"
        }
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The Corveil palette a skin falls back to, read from `theme.css` (under
    /// `--web-dir` when set). Used to resolve and contrast-check a skin.
    static func base(webDir: String?) -> WebSkinBase {
        var url: URL?
        if let webDir {
            let candidate = URL(fileURLWithPath: webDir).appendingPathComponent("theme.css")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
        }
        url = url ?? Bundle.module.url(forResource: "theme", withExtension: "css", subdirectory: "web")
        guard let url, let css = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return WebSkinBase.parse(themeCSS: css)
    }

    private static func sorted(_ skins: [WebSkin]) -> [WebSkin] {
        skins.sorted { lhs, rhs in
            if lhs.id == WebSkin.defaultID { return rhs.id != WebSkin.defaultID }
            if rhs.id == WebSkin.defaultID { return false }
            let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
        }
    }

    // Lists the directory rather than `Bundle.urls(forResourcesWithExtension:)`,
    // which returns `[NSURL]` on Linux Foundation and breaks the Linux crowd build.
    private static func skinFiles(webDir: String?) -> [URL] {
        if let webDir, let files = jsonFiles(in: URL(fileURLWithPath: webDir).appendingPathComponent("skins")) {
            return files
        }
        // Same lookup StaticAssets uses for web files, which builds on Linux.
        guard let dir = Bundle.module.url(forResource: "skins", withExtension: nil, subdirectory: "web") else { return [] }
        return jsonFiles(in: dir) ?? []
    }

    private static func jsonFiles(in dir: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { $0.hasSuffix(".json") }.sorted().map { dir.appendingPathComponent($0) }
    }
}
