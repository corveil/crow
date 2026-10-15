import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

/// The `crow skin` verb family (CROW-1334): the web UI skins `crowd` serves.
///
/// Built-in skins ship with crowd; custom skins are JSON files in
/// `~/Library/Application Support/crow/skins/` (the same format, see
/// `docs/web-skins.md`). Every write reaches open browsers within a few
/// seconds, without a `crowd` restart. Validation errors block a write;
/// contrast problems only warn — they come back under `warnings` and are
/// echoed to stderr.
public struct Skin: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "skin",
        abstract: "List, make, install and remove web UI skins",
        subcommands: [
            SkinList.self, SkinGet.self, SkinCreate.self, SkinAdd.self,
            SkinExport.self, SkinRemove.self, SkinDefault.self,
        ]
    )

    public init() {}
}

/// Echo each contrast warning in a write's result to stderr, so a person sees
/// them without reading the JSON. The JSON still carries them for scripts.
func echoSkinWarnings(_ result: [String: JSONValue]) {
    for warning in result["warnings"]?.arrayValue ?? [] {
        if let message = warning.objectValue?["message"]?.stringValue {
            FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
        }
    }
}

/// A skin id the way `WebSkin` accepts one; the daemon checks it again.
func validateSkinID(_ id: String, flag: String) throws {
    guard WebSkin.isValidID(id) else {
        throw ValidationError("\(flag) '\(id)' must be lowercase letters, digits and dashes (max 64).")
    }
}

// MARK: - list / get

public struct SkinList: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the skins crowd serves, built in and custom, and the default"
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("skin-list"))
    }
}

public struct SkinGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show one skin with every token resolved",
        discussion: """
        A skin file only holds the tokens it changes; the rest fall back to \
        Corveil. `get` fills them in, so `skin` lists every token as it applies.
        """
    )

    @Option(name: .long, help: "Skin id")
    var id: String

    public init() {}

    public func validate() throws { try validateSkinID(id, flag: "--id") }

    public func run() throws {
        printJSON(try rpc("skin-get", params: ["id": .string(id)]))
    }
}

// MARK: - create

public struct SkinCreate: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Make a custom skin from an existing one",
        discussion: """
        Copies --from, renames it, and applies --set (dark) and --set-light \
        (light) overrides. TOKEN may omit the leading dashes: `--set \
        accent=#7AA2F7` sets `--accent`. --set-light on a dark-only source \
        gives the new skin a light mode built on Corveil's light palette.

          crow skin create --from corveil-classic --name "Dusty" --set accent=#7AA2F7
        """
    )

    @Option(name: .long, help: "Skin to start from (an id from `skin list`)")
    var from: String

    @Option(name: .long, help: "Display name")
    var name: String

    @Option(name: .long, help: "Skin id (default: the name, lowercased and dashed)")
    var id: String?

    @Option(name: .customLong("set"), help: ArgumentHelp("Dark-mode override (repeatable)", valueName: "TOKEN=VALUE"))
    var set: [String] = []

    @Option(name: .customLong("set-light"), help: ArgumentHelp("Light-mode override (repeatable)", valueName: "TOKEN=VALUE"))
    var setLight: [String] = []

    public init() {}

    public func validate() throws {
        try validateSkinID(from, flag: "--from")
        if let id { try validateSkinID(id, flag: "--id") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--name must not be blank.")
        }
        if id == nil, WebSkinStore.slug(name) == nil {
            throw ValidationError("Can't derive an id from --name \"\(name)\"; pass --id.")
        }
        _ = try Self.parse(set, flag: "--set")
        _ = try Self.parse(setLight, flag: "--set-light")
    }

    /// `["accent=#7AA2F7"]` → `["--accent": "#7AA2F7"]`, rejecting a malformed
    /// pair or a name that is not a skin token. Values are checked by the daemon.
    static func parse(_ raw: [String], flag: String) throws -> [String: String] {
        var out: [String: String] = [:]
        let known = Set(WebSkin.tokens)
        for item in raw {
            guard let (token, value) = WebSkinStore.assignment(item) else {
                throw ValidationError("\(flag) '\(item)' must be TOKEN=VALUE, e.g. accent=#7AA2F7.")
            }
            guard known.contains(token) else {
                throw ValidationError("\(flag): \(token) is not a skin token (see docs/web-skins.md).")
            }
            out[token] = value
        }
        return out
    }

    public func run() throws {
        var params: [String: JSONValue] = [
            "from": .string(from),
            "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        if let id { params["id"] = .string(id) }
        let dark = try Self.parse(set, flag: "--set")
        let light = try Self.parse(setLight, flag: "--set-light")
        if !dark.isEmpty { params["set"] = .object(dark.mapValues(JSONValue.string)) }
        if !light.isEmpty { params["set_light"] = .object(light.mapValues(JSONValue.string)) }
        let result = try rpc("skin-create", params: params)
        echoSkinWarnings(result)
        printJSON(result)
    }
}

// MARK: - add / export / remove

public struct SkinAdd: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Validate a skin file and install it as a custom skin",
        discussion: """
        Copies the file into ~/Library/Application Support/crow/skins/. It must \
        be a skin JSON file (see docs/web-skins.md); a malformed or invalid one \
        is rejected with the reason. --id installs it under another id. Local \
        only: the daemon reads the path, so it is refused over remote /rpc.
        """
    )

    @Argument(help: "Path to a skin .json file")
    var path: String

    @Option(name: .long, help: "Install under this id instead of the file's")
    var id: String?

    public init() {}

    public func validate() throws {
        _ = try resolvedReadableFilePath(path)
        if let id { try validateSkinID(id, flag: "--id") }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["path": .string(try resolvedReadableFilePath(path))]
        if let id { params["id"] = .string(id) }
        let result = try rpc("skin-add", params: params)
        echoSkinWarnings(result)
        printJSON(result)
    }
}

public struct SkinExport: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Write a skin as a self-contained skin file",
        discussion: """
        Every token is written out, resolved against Corveil, so the file is a \
        complete starting point: edit it, then `crow skin add` it under a new \
        --id. Prints to stdout unless --out is given.
        """
    )

    @Option(name: .long, help: "Skin id")
    var id: String

    @Option(name: .long, help: "File to write (default: stdout)")
    var out: String?

    public init() {}

    public func validate() throws { try validateSkinID(id, flag: "--id") }

    public func run() throws {
        let result = try rpc("skin-get", params: ["id": .string(id)])
        guard let skin = result["skin"] else {
            throw ValidationError("crowd returned no skin for '\(id)'.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(skin)
        data.append(0x0A)
        guard let out else {
            FileHandle.standardOutput.write(data)
            return
        }
        let url = URL(fileURLWithPath: NSString(string: out).expandingTildeInPath)
        try data.write(to: url, options: .atomic)
        printJSON(["exported": .bool(true), "id": .string(id), "path": .string(url.path)])
    }
}

public struct SkinRemove: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a custom skin (built-ins cannot be removed)",
        discussion: """
        Browsers using it fall back to the default. If it was the default, the \
        default is cleared back to Corveil (`default_cleared`).
        """
    )

    @Option(name: .long, help: "Custom skin id")
    var id: String

    public init() {}

    public func validate() throws { try validateSkinID(id, flag: "--id") }

    public func run() throws {
        printJSON(try rpc("skin-remove", params: ["id": .string(id)]))
    }
}

// MARK: - default

public struct SkinDefault: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "default",
        abstract: "Set or clear the daemon-wide default skin",
        discussion: """
        A browser that has not picked a skin in Settings uses the default; one \
        that has keeps its own choice.
        """,
        subcommands: [SkinDefaultSet.self, SkinDefaultClear.self]
    )

    public init() {}
}

public struct SkinDefaultSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Make a skin the default for browsers that haven't chosen one"
    )

    @Argument(help: "Skin id")
    var id: String

    public init() {}

    public func validate() throws { try validateSkinID(id, flag: "id") }

    public func run() throws {
        printJSON(try rpc("skin-default-set", params: ["id": .string(id)]))
    }
}

public struct SkinDefaultClear: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Reset the default skin to Corveil"
    )

    public init() {}

    public func run() throws {
        printJSON(try rpc("skin-default-clear"))
    }
}
