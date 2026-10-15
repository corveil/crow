import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// Web UI skins (CROW-1334): `crow skin list|get|create|add|remove|default`.
///
/// Built-ins come from `web/skins/*.json` and cannot be removed or shadowed;
/// custom skins live in ``WebSkinStore`` and are read per request, so every
/// write here reaches open browsers on their next `/skins.json` poll without a
/// `crowd` restart. Validation (`WebSkin.validationErrors`) blocks a write;
/// contrast (`WebSkinContrast`) only warns, and the warnings ride along in
/// every write's result.
///
/// `skin-add` is local-only in `RPCWebSocketHandler.localOnlyDenial` — it reads
/// a host path, like `notifications-add-sound`. The rest are un-gated: a skin is
/// validated CSS that can't escape its declarations, and the default it can set
/// is already one of the listed skins.
func makeSkinHandlers(sources: WebSkinSources, devRoot: String) -> [String: CommandRouter.Handler] {
    let handlers: [String: CommandRouter.Handler] = [
        "skin-list": { _ in
            let listed = WebSkinCatalog.listing(sources)
            var result: [String: JSONValue] = [
                "skins": .array(listed.map(SkinRPC.summaryJSON)),
                "default": .string(WebSkinCatalog.defaultID(sources, listed: listed)),
            ]
            if let store = sources.store { result["store"] = .string(store.directory.path) }
            return result
        },
        "skin-get": { params in
            try await mapRPCError {
                let id = try SkinRPC.requiredString(params, "id")
                guard let listed = WebSkinCatalog.skin(id: id, sources: sources) else {
                    throw RPCError.invalidParams(SkinRPC.unknown(id))
                }
                let base = WebSkinCatalog.base(webDir: sources.webDir)
                return [
                    "skin": SkinRPC.skinJSON(base.flattened(listed.skin)),
                    "builtin": .bool(listed.builtin),
                    "warnings": SkinRPC.warningsJSON(WebSkinContrast.warnings(for: listed.skin, base: base)),
                ]
            }
        },
        "skin-create": { params in
            try await mapRPCError {
                let store = try SkinRPC.store(sources)
                let from = try SkinRPC.requiredString(params, "from")
                let name = try SkinRPC.requiredString(params, "name")
                guard let source = WebSkinCatalog.skin(id: from, sources: sources)?.skin else {
                    throw RPCError.invalidParams(SkinRPC.unknown(from))
                }
                let id = try SkinRPC.newID(params["id"]?.stringValue, name: name)
                let dark = try SkinRPC.assignments(params, "set")
                let light = try SkinRPC.assignments(params, "set_light")
                var skin = WebSkin(
                    id: id, name: name,
                    dark: source.dark.merging(dark) { $1 },
                    light: source.light, fonts: source.fonts)
                if !light.isEmpty { skin.light = (source.light ?? [:]).merging(light) { $1 } }
                return try SkinRPC.save(skin, store: store, sources: sources)
            }
        },
        "skin-add": { params in
            try await mapRPCError {
                let store = try SkinRPC.store(sources)
                let path = try SkinRPC.requiredString(params, "path")
                guard path.hasPrefix("/") else {
                    throw RPCError.invalidParams(
                        "path must be absolute (it is resolved by the daemon, not your shell)")
                }
                var skin: WebSkin
                do {
                    skin = try WebSkinStore.read(path: path)
                } catch let error as WebSkinStoreError {
                    throw RPCError.invalidParams(error.localizedDescription)
                }
                if let id = params["id"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                    skin.id = id
                }
                return try SkinRPC.save(skin, store: store, sources: sources)
            }
        },
        "skin-remove": { params in
            try await mapRPCError {
                let store = try SkinRPC.store(sources)
                let id = try SkinRPC.requiredString(params, "id")
                if WebSkinCatalog.builtinIDs(webDir: sources.webDir).contains(id) {
                    throw RPCError.invalidParams(WebSkinStoreError.builtin(id).localizedDescription)
                }
                do {
                    try store.remove(id: id)
                } catch let error as WebSkinStoreError {
                    throw RPCError.invalidParams(error.localizedDescription)
                }
                // A default that names the removed skin would silently fall back
                // anyway; clearing it keeps `skin list` honest about why.
                let cleared = try mutateConfig(devRoot: devRoot) { config -> Bool in
                    guard config.webDefaultSkin == id else { return false }
                    config.webDefaultSkin = nil
                    return true
                }
                return ["removed": .bool(true), "id": .string(id), "default_cleared": .bool(cleared)]
            }
        },
        "skin-default-set": { params in
            try await mapRPCError {
                let id = try SkinRPC.requiredString(params, "id")
                guard WebSkinCatalog.skin(id: id, sources: sources) != nil else {
                    throw RPCError.invalidParams(SkinRPC.unknown(id))
                }
                try mutateConfig(devRoot: devRoot) { config in
                    config.webDefaultSkin = id == WebSkin.defaultID ? nil : id
                }
                return ["default": .string(id), "saved": .bool(true)]
            }
        },
        "skin-default-clear": { _ in
            try await mapRPCError {
                try mutateConfig(devRoot: devRoot) { config in config.webDefaultSkin = nil }
                return ["default": .string(WebSkin.defaultID), "saved": .bool(true)]
            }
        },
    ]
    return handlers
}

/// Payload shaping and param parsing for the skin handlers.
enum SkinRPC {
    static func summaryJSON(_ listed: WebSkinCatalog.Listed) -> JSONValue {
        .object([
            "id": .string(listed.skin.id),
            "name": .string(listed.skin.name),
            "builtin": .bool(listed.builtin),
            "modes": .array((listed.skin.supportsLight ? ["dark", "light"] : ["dark"]).map(JSONValue.string)),
        ])
    }

    /// The skin in its file format, so `export` can write it verbatim.
    static func skinJSON(_ skin: WebSkin) -> JSONValue {
        func map(_ m: [String: String]) -> JSONValue { .object(m.mapValues(JSONValue.string)) }
        var out: [String: JSONValue] = [
            "id": .string(skin.id), "name": .string(skin.name), "dark": map(skin.dark),
        ]
        if let light = skin.light { out["light"] = map(light) }
        if let fonts = skin.fonts {
            var f: [String: JSONValue] = [:]
            if let ui = fonts.ui { f["ui"] = .string(ui) }
            if let mono = fonts.mono { f["mono"] = .string(mono) }
            out["fonts"] = .object(f)
        }
        return .object(out)
    }

    static func warningsJSON(_ warnings: [WebSkinContrast.Warning]) -> JSONValue {
        .array(warnings.map {
            .object([
                "mode": .string($0.mode),
                "foreground": .string($0.foreground),
                "background": .string($0.background),
                "ratio": .double($0.ratio),
                "minimum": .double($0.minimum),
                "message": .string($0.description),
            ])
        })
    }

    static func unknown(_ id: String) -> String {
        "No skin with id '\(id)'. `crow skin list` shows the ids."
    }

    static func store(_ sources: WebSkinSources) throws -> WebSkinStore {
        guard let store = sources.store else {
            throw RPCError.applicationError("This crowd has no custom skin store.")
        }
        return store
    }

    static func requiredString(_ params: [String: JSONValue], _ key: String) throws -> String {
        guard let raw = params[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw RPCError.invalidParams("\(key) required")
        }
        return raw
    }

    /// `--id` when given, else the name slugged (`Dusty Rose` → `dusty-rose`).
    static func newID(_ raw: String?, name: String) throws -> String {
        if let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty { return raw }
        guard let slug = WebSkinStore.slug(name) else {
            throw RPCError.invalidParams(
                "Can't derive an id from the name \"\(name)\"; pass --id (lowercase letters, digits, dashes).")
        }
        return slug
    }

    /// `{"accent": "#7AA2F7"}` → `["--accent": "#7AA2F7"]`. Unknown names and
    /// bad values are left for `validationErrors` to report together.
    static func assignments(_ params: [String: JSONValue], _ key: String) throws -> [String: String] {
        guard let value = params[key] else { return [:] }
        guard let object = value.objectValue else {
            throw RPCError.invalidParams("\(key) must be an object of token → value")
        }
        var out: [String: String] = [:]
        for (token, raw) in object {
            guard let string = raw.stringValue else {
                throw RPCError.invalidParams("\(key).\(token) must be a string")
            }
            out[WebSkinStore.tokenName(token)] = string.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Refuse a built-in id, then write through the store (which validates and
    /// refuses an existing file). Contrast warnings come back with the result.
    static func save(
        _ skin: WebSkin, store: WebSkinStore, sources: WebSkinSources
    ) throws -> [String: JSONValue] {
        if WebSkinCatalog.builtinIDs(webDir: sources.webDir).contains(skin.id) {
            throw RPCError.invalidParams(WebSkinStoreError.builtin(skin.id).localizedDescription)
        }
        do {
            try store.save(skin)
        } catch let error as WebSkinStoreError {
            throw RPCError.invalidParams(error.localizedDescription)
        }
        let base = WebSkinCatalog.base(webDir: sources.webDir)
        return [
            "skin": summaryJSON(.init(skin: skin, builtin: false)),
            "path": .string(store.fileURL(id: skin.id).path),
            "warnings": warningsJSON(WebSkinContrast.warnings(for: skin, base: base)),
            "saved": .bool(true),
        ]
    }
}
