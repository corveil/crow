import Foundation

/// Why a custom-skin operation failed (CROW-1334). Messages are shown verbatim
/// by the CLI.
public enum WebSkinStoreError: Error, LocalizedError, Equatable {
    case fileNotFound(String)
    case tooLarge(maxBytes: Int)
    case malformed(String)
    case invalid([String])
    case builtin(String)
    case alreadyExists(String)
    case missing(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "'\(path)' is not a readable file."
        case .tooLarge(let max):
            return "Skin file is too large. Maximum size is \(max / 1024) KB."
        case .malformed(let detail):
            return "Not a skin file: \(detail)"
        case .invalid(let problems):
            return "Invalid skin: " + problems.joined(separator: "; ")
        case .builtin(let id):
            return "'\(id)' is a built-in skin. Built-in skins cannot be replaced or removed; pick another --id."
        case .alreadyExists(let id):
            return "A custom skin with id '\(id)' already exists. Remove it first, or pick another --id."
        case .missing(let id):
            return "No custom skin with id '\(id)'."
        case .io(let message):
            return message
        }
    }
}

/// Operator-made web UI skins (CROW-1334), one `<id>.json` per skin in the
/// same format as the built-ins (``WebSkin``).
///
/// Lives at `~/Library/Application Support/crow/skins/` (or the platform
/// equivalent, next to the custom sound library). The directory is the source
/// of truth: `crowd` reads it per request, so a file dropped in, written by
/// `crow skin create`/`add` or deleted by `remove` shows up without a restart.
///
/// The store does not know which ids are built in — `crowd` does, and refuses
/// to let a custom skin shadow one. Tests **must** construct one with an
/// explicit temporary `directory:`, never `.live` (ADR 0012).
public struct WebSkinStore: Sendable {
    /// Cap for one skin file. The full token set is a few KB.
    public static let maxBytes = 256 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Production store under Application Support. Tests must not use this.
    public static var live: WebSkinStore { WebSkinStore(directory: defaultDirectory) }

    /// `~/Library/Application Support/crow/skins/` (macOS) or the platform
    /// Application Support equivalent. Created on first write, not on read.
    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("crow", isDirectory: true)
            .appendingPathComponent("skins", isDirectory: true)
    }

    /// A unique temp directory for tests. Caller is responsible for cleanup.
    public static func temporary() -> WebSkinStore {
        WebSkinStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-test-skins-\(UUID().uuidString)", isDirectory: true))
    }

    // MARK: - Reading

    /// One `*.json` in the store, parsed or not.
    public struct Entry: Sendable {
        public let file: String
        public let skin: WebSkin?
        /// Why the file is not served; empty for a usable skin.
        public let problems: [String]
    }

    /// Every `*.json` file, sorted by name, each with its parse/validation
    /// result. A file is usable only when it decodes, validates, and is named
    /// after its id.
    public func entries() -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { file in
            let url = directory.appendingPathComponent(file)
            let data: Data
            do {
                data = try Self.readCapped(url)
            } catch {
                return Entry(file: file, skin: nil, problems: [error.localizedDescription])
            }
            do {
                let skin = try Self.decode(data)
                var problems = skin.validationErrors().map(\.description)
                if file != "\(skin.id).json" {
                    problems.append("file must be named \(skin.id).json")
                }
                return Entry(file: file, skin: skin, problems: problems)
            } catch {
                return Entry(file: file, skin: nil, problems: [error.localizedDescription])
            }
        }
    }

    /// The usable skins.
    public func skins() -> [WebSkin] {
        entries().compactMap { $0.problems.isEmpty ? $0.skin : nil }
    }

    public func skin(id: String) -> WebSkin? {
        guard WebSkin.isValidID(id) else { return nil }
        return skins().first { $0.id == id }
    }

    /// Whether a file for `id` exists at all, usable or not. `save` refuses to
    /// overwrite one either way.
    public func fileExists(id: String) -> Bool {
        WebSkin.isValidID(id) && FileManager.default.fileExists(atPath: fileURL(id: id).path)
    }

    public func fileURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    // MARK: - Decoding

    /// Decode a skin file, turning `DecodingError` into a sentence that names
    /// the field.
    public static func decode(_ data: Data) throws -> WebSkin {
        do {
            return try JSONDecoder().decode(WebSkin.self, from: data)
        } catch let error as DecodingError {
            throw WebSkinStoreError.malformed(describe(error))
        } catch {
            throw WebSkinStoreError.malformed(error.localizedDescription)
        }
    }

    /// Read a skin file from an arbitrary path (for `crow skin add`).
    public static func read(path: String) throws -> WebSkin {
        try decode(readCapped(URL(fileURLWithPath: path)))
    }

    private static func readCapped(_ url: URL) throws -> Data {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw WebSkinStoreError.fileNotFound(url.path)
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
           size > maxBytes {
            throw WebSkinStoreError.tooLarge(maxBytes: maxBytes)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw WebSkinStoreError.fileNotFound(url.path)
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let p = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
                .joined(separator: ".")
            return p.isEmpty ? "the top level" : "\"\(p)\""
        }
        switch error {
        case .keyNotFound(let key, let context):
            let at = context.codingPath.isEmpty ? "" : " in \(path(context))"
            return "missing required key \"\(key.stringValue)\"\(at)"
        case .typeMismatch(let type, let context):
            return "\(path(context)) must be \(typeName(type))"
        case .valueNotFound(let type, let context):
            return "\(path(context)) must be \(typeName(type)), not null"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty
                ? "not valid JSON" : "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return "could not be decoded"
        }
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is [String: String].Type, is [String: Any].Type: return "an object"
        default: return "a \(type)"
        }
    }

    // MARK: - Writing

    /// Write `skin` as `<id>.json`. Validates first; refuses to overwrite an
    /// existing file. Shadowing a built-in is the caller's check.
    public func save(_ skin: WebSkin) throws {
        let problems = skin.validationErrors().map(\.description)
        guard problems.isEmpty else { throw WebSkinStoreError.invalid(problems) }
        guard !fileExists(id: skin.id) else { throw WebSkinStoreError.alreadyExists(skin.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(skin).write(to: fileURL(id: skin.id), options: .atomic)
        } catch {
            throw WebSkinStoreError.io("Could not write \(fileURL(id: skin.id).path): \(error.localizedDescription)")
        }
    }

    /// Delete `<id>.json`, usable or not.
    public func remove(id: String) throws {
        guard fileExists(id: id) else { throw WebSkinStoreError.missing(id) }
        do {
            try FileManager.default.removeItem(at: fileURL(id: id))
        } catch {
            throw WebSkinStoreError.io("Could not remove \(fileURL(id: id).path): \(error.localizedDescription)")
        }
    }

    // MARK: - Making a skin

    /// `Dusty Rose` → `dusty-rose`: lowercase ASCII letters and digits, runs of
    /// anything else collapsed to one dash. Nil when nothing usable is left.
    public static func slug(_ name: String) -> String? {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out += "-"
            }
        }
        var id = String(out.prefix(64))
        while id.hasSuffix("-") { id.removeLast() }
        return WebSkin.isValidID(id) ? id : nil
    }

    /// `accent` and `--accent` both name `--accent`.
    public static func tokenName(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("--") ? t : "--" + t
    }

    /// Parse `TOKEN=VALUE` (`--set accent=#7AA2F7`). The value may itself hold
    /// `=`; only the first one splits.
    public static func assignment(_ raw: String) -> (token: String, value: String)? {
        guard let eq = raw.firstIndex(of: "=") else { return nil }
        let token = tokenName(String(raw[..<eq]))
        let value = raw[raw.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard token.count > 2, !value.isEmpty else { return nil }
        return (token, value)
    }
}
