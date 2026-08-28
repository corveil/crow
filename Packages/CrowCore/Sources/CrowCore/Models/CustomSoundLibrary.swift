import Foundation

/// One user-supplied notification sound, stored as a file under the library
/// directory. `name` is what pickers and `--event-sound-name` use; `file` is
/// the on-disk filename; `url` is the web path the client fetches to play it.
///
/// Bytes never enter `config.json` — per-event `soundName` holds this `name`
/// as a reference, the same way built-in macOS sound names are stored.
public struct CustomSound: Sendable, Equatable {
    public var name: String
    public var file: String
    public var url: String

    public init(name: String, file: String, url: String) {
        self.name = name
        self.file = file
        self.url = url
    }
}

/// Why adding or removing a custom sound failed. Messages are shown verbatim
/// by the CLI and the Settings upload row.
public enum CustomSoundError: Error, LocalizedError, Equatable {
    case fileNotFound(String)
    case unsupportedFormat
    case tooLarge(maxBytes: Int)
    case invalidName
    case nameConflict(String)
    case notAudio
    case missing(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "'\(path)' is not a readable file."
        case .unsupportedFormat:
            return "Unsupported sound format. Expected .wav, .mp3, or .aiff."
        case .tooLarge(let max):
            return "Sound file is too large. Maximum size is \(max / (1024 * 1024)) MB."
        case .invalidName:
            return "Sound name is empty or contains no usable characters."
        case .nameConflict(let name):
            return "'\(name)' already exists as a sound name. Pick a different name, or remove the existing one first."
        case .notAudio:
            return "File does not look like a .wav, .mp3, or .aiff audio file."
        case .missing(let name):
            return "No custom sound named '\(name)'."
        case .io(let message):
            return message
        }
    }
}

/// On-disk library of custom notification sounds.
///
/// Lives at `~/Library/Application Support/crow/sounds/` (or the platform
/// equivalent). The directory is the source of truth — dropping a valid file
/// in is enough for it to show up in `available_sounds` on the next get.
/// Uploads (Settings) and `crow notifications add-sound` copy into it.
///
/// Tests **must** construct one with an explicit temporary `directory:` —
/// never `.live` — so they cannot read or write the user's library (ADR 0012).
public struct CustomSoundLibrary: Sendable {
    /// Extensions accepted for upload, drop-in, and HTTP serve.
    public static let allowedExtensions: Set<String> = ["wav", "mp3", "aiff", "aif"]

    /// Cap for a single custom sound (2 MB). Notification chimes are short;
    /// this also stays well under what a Settings upload should ship.
    public static let maxBytes = 2 * 1024 * 1024

    /// Web path prefix the client fetches. Kept here so the RPC listing and
    /// the HTTP route cannot drift.
    public static let urlPrefix = "/sounds/"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Production library under Application Support. Tests must not use this —
    /// pass a unique temp directory instead.
    public static var live: CustomSoundLibrary {
        CustomSoundLibrary(directory: defaultDirectory)
    }

    /// `~/Library/Application Support/crow/sounds/` (macOS) or the platform
    /// Application Support equivalent. Created on first add, not on list.
    public static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("crow", isDirectory: true)
            .appendingPathComponent("sounds", isDirectory: true)
    }

    /// A unique temp directory for tests. Caller is responsible for cleanup.
    public static func temporary() -> CustomSoundLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-test-sounds-\(UUID().uuidString)", isDirectory: true)
        return CustomSoundLibrary(directory: dir)
    }

    // MARK: - Listing

    /// Valid audio files in the library, sorted by display name.
    /// Hidden files, wrong extensions, built-in-name collisions, and duplicate
    /// stems (first wins) are skipped.
    public func list() -> [CustomSound] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var seen = Set<String>()
        var sounds: [CustomSound] = []
        for url in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let file = url.lastPathComponent
            guard Self.isSafeFileName(file) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard Self.fileSize(url) <= Self.maxBytes else { continue }
            let name = (file as NSString).deletingPathExtension
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            // Built-ins win the picker; a dropped Glass.wav must not duplicate them.
            if NotificationSettings.canonicalSoundName(name) != nil { continue }
            guard seen.insert(key).inserted else { continue }
            sounds.append(CustomSound(name: name, file: file, url: Self.url(for: file)))
        }
        return sounds.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Display names currently in the library.
    public var names: [String] { list().map(\.name) }

    /// Look up a custom sound by display name (case-insensitive).
    public func sound(named raw: String) -> CustomSound? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return list().first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// Resolve a stored `soundName` to a custom file URL for serving, or nil
    /// when it isn't a custom sound (built-in, missing, or unsafe).
    public func fileURL(named raw: String) -> URL? {
        guard let sound = sound(named: raw) else { return nil }
        return resolvedFile(sound.file)
    }

    /// Resolve a served filename to a regular file still inside `directory`.
    public func resolvedFile(_ file: String) -> URL? {
        guard Self.isSafeFileName(file) else { return nil }
        let candidate = directory.appendingPathComponent(file)
        guard let url = Self.resolvedPathInside(dir: directory, file: candidate) else { return nil }
        guard Self.fileSize(url) <= Self.maxBytes else { return nil }
        return url
    }

    // MARK: - Add / remove

    /// Copy `source` into the library. `requestedName` overrides the stem.
    public func add(from source: URL, requestedName: String? = nil) throws -> CustomSound {
        let path = source.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            throw CustomSoundError.fileNotFound(path)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let size = attrs?[.size] as? Int, size > Self.maxBytes {
            throw CustomSoundError.tooLarge(maxBytes: Self.maxBytes)
        }
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw CustomSoundError.fileNotFound(path)
        }
        return try add(data: data, filename: source.lastPathComponent, requestedName: requestedName)
    }

    /// Store `data` as a new library entry. Used by the HTTP upload route.
    public func add(data: Data, filename: String, requestedName: String? = nil) throws -> CustomSound {
        guard !data.isEmpty else { throw CustomSoundError.notAudio }
        guard data.count <= Self.maxBytes else {
            throw CustomSoundError.tooLarge(maxBytes: Self.maxBytes)
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard Self.allowedExtensions.contains(ext) else {
            throw CustomSoundError.unsupportedFormat
        }
        guard Self.looksLikeAudio(data, ext: ext) else {
            throw CustomSoundError.notAudio
        }
        let trimmedRequested = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stemSource = (trimmedRequested?.isEmpty == false ? trimmedRequested : nil)
            ?? (filename as NSString).deletingPathExtension
        guard let stem = Self.sanitizeStem(stemSource) else {
            throw CustomSoundError.invalidName
        }
        if let builtIn = NotificationSettings.canonicalSoundName(stem) {
            throw CustomSoundError.nameConflict(builtIn)
        }
        if let existing = sound(named: stem) {
            throw CustomSoundError.nameConflict(existing.name)
        }
        // Normalize aif → aiff so served names stay in the documented set.
        let storedExt = ext == "aif" ? "aiff" : ext
        let file = "\(stem).\(storedExt)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        } catch {
            throw CustomSoundError.io(error.localizedDescription)
        }
        return CustomSound(name: stem, file: file, url: Self.url(for: file))
    }

    /// Delete the file for `name`. Events that still reference it keep the
    /// name in config; playback falls back to a default when the file is gone.
    public func remove(name raw: String) throws {
        guard let sound = sound(named: raw) else {
            throw CustomSoundError.missing(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let url = directory.appendingPathComponent(sound.file)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw CustomSoundError.io(error.localizedDescription)
        }
    }

    // MARK: - Guards

    /// A bare audio filename: non-empty, no separators, no `..`, allowed ext.
    public static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains("..")
            && allowedExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Stem used as the display / `--event-sound-name` value: `[A-Za-z0-9_-]`,
    /// spaces become hyphens, 1–64 chars. Nil when nothing usable remains.
    public static func sanitizeStem(_ raw: String) -> String? {
        let spaced = raw.replacingOccurrences(of: " ", with: "-")
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let cleaned = String(String.UnicodeScalarView(spaced.unicodeScalars.filter { allowed.contains($0) }))
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(64))
    }

    /// Magic-byte sniff so a renamed `.txt` can't be stored as `.wav` and then
    /// served from the daemon origin.
    public static func looksLikeAudio(_ data: Data, ext: String) -> Bool {
        guard data.count >= 12 else { return false }
        switch ext {
        case "wav":
            return data.starts(with: Array("RIFF".utf8))
                && data.dropFirst(8).starts(with: Array("WAVE".utf8))
        case "aiff", "aif":
            return data.starts(with: Array("FORM".utf8))
                && (data.dropFirst(8).starts(with: Array("AIFF".utf8))
                    || data.dropFirst(8).starts(with: Array("AIFC".utf8)))
        case "mp3":
            if data.starts(with: Array("ID3".utf8)) { return true }
            return data[0] == 0xFF && (data[1] & 0xE0) == 0xE0
        default:
            return false
        }
    }

    /// File size in bytes, or `Int.max` when unknown so callers skip it.
    public static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let n = attrs?[.size] as? NSNumber { return n.intValue }
        if let n = attrs?[.size] as? Int { return n }
        return Int.max
    }

    public static func url(for file: String) -> String {
        let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return urlPrefix + encoded
    }

    public static func contentType(for file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "aiff", "aif": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    /// Resolve `file` (following symlinks) and return it only when the final
    /// path is still under `dir`. Mirrors `Artifacts.resolvedPathInside`.
    public static func resolvedPathInside(dir: URL, file: URL) -> URL? {
        let root = dir.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == root || resolved.hasPrefix(root + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: resolved)
    }
}
