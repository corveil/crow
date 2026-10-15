import CrowCore
import Foundation

/// The skins `crowd` serves to the web UI (CROW-1333): every valid
/// `web/skins/*.json`, read from `--web-dir` when set (edit + refresh, like the
/// rest of the UI) and from the daemon bundle otherwise.
///
/// Read per request. There are a handful of small files, and reading them live
/// keeps `--web-dir` honest without a cache to invalidate.
enum WebSkinCatalog {
    /// Valid skins, the default (Corveil) first and the rest by name. An
    /// invalid file is skipped rather than served: its CSS could not be trusted
    /// to stay inside its declarations.
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
        return byID.values.sorted { lhs, rhs in
            if lhs.id == WebSkin.defaultID { return rhs.id != WebSkin.defaultID }
            if rhs.id == WebSkin.defaultID { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func skin(id: String, webDir: String?) -> WebSkin? {
        guard WebSkin.isValidID(id) else { return nil }
        return load(webDir: webDir).first { $0.id == id }
    }

    /// `GET /skins.json`: what the Settings picker lists and what `theme.js`
    /// needs to know before it asks for CSS (whether a skin has a light mode).
    static func catalogJSON(webDir: String?) -> Data {
        struct Entry: Encodable {
            let id: String
            let name: String
            let light: Bool
        }
        struct Catalog: Encodable {
            let defaultSkin: String
            let skins: [Entry]
            enum CodingKeys: String, CodingKey {
                case defaultSkin = "default"
                case skins
            }
        }
        let catalog = Catalog(
            defaultSkin: WebSkin.defaultID,
            skins: load(webDir: webDir).map { Entry(id: $0.id, name: $0.name, light: $0.supportsLight) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(catalog)) ?? Data("{\"default\":\"corveil\",\"skins\":[]}".utf8)
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
