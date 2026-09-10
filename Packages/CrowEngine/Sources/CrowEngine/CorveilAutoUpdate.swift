import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Pure helpers for auto-downloading the `corveil` CLI from
/// `corveil/corveil-releases` (CROW-1210).
///
/// Network, hashing, and config writes live in `CorveilAutoUpdateService`
/// (CrowDaemon). This type is the policy: platform asset names, checksum
/// tables, managed-dir layout, and "does this configured path count as an
/// operator override?". Keeping it here lets the rules be unit-tested without
/// a daemon, a GitHub round-trip, or Application Support (ADR 0012).
public enum CorveilAutoUpdate {
    public static let checksumsAssetName = "checksums.txt"
    public static let binaryFileName = "corveil"
    /// Upper bound on a downloaded asset. The published CLIs are tens of MB;
    /// anything larger is treated as a bad/malicious payload rather than written.
    public static let maxAssetBytes = 80 * 1024 * 1024

    public static var hostOperatingSystem: String {
        #if os(macOS)
        "darwin"
        #elseif os(Linux)
        "linux"
        #else
        "unsupported"
        #endif
    }

    public static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "amd64"
        #else
        "unsupported"
        #endif
    }

    /// `corveil-<os>-<arch>` as published on `corveil/corveil-releases`.
    public static func assetName(os: String = hostOperatingSystem, arch: String = hostArchitecture) -> String {
        let mappedArch = arch == "x86_64" ? "amd64" : arch
        return "corveil-\(os)-\(mappedArch)"
    }

    /// Directory holding versioned installs: `{managedRoot}/<tag>/corveil`.
    public static func versionDirectory(tag: String, managedRoot: URL) -> URL {
        managedRoot.appendingPathComponent(tag, isDirectory: true)
    }

    public static func binaryURL(tag: String, managedRoot: URL) -> URL {
        versionDirectory(tag: tag, managedRoot: managedRoot)
            .appendingPathComponent(binaryFileName, isDirectory: false)
    }

    /// True when `path` is inside Crow's managed corveil dir (the auto-updater
    /// owns it). An operator-set source-build path is anything else.
    public static func isManagedPath(_ path: String, managedRoot: URL) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let root = managedRoot.standardizedFileURL.path
        if standardized == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return standardized.hasPrefix(prefix)
    }

    /// Crow manages the binary only when auto-update is on **and** the
    /// configured path is unset or already a managed install. A real source
    /// build in `binaries["corveil"]` always wins.
    public static func shouldAutoManage(configuredPath: String?, managedRoot: URL) -> Bool {
        guard let path = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return true
        }
        return isManagedPath(path, managedRoot: managedRoot)
    }

    /// Parse GNU `sha256sum` output (`<hex>  <name>` or `<hex> *<name>`).
    public static func parseChecksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let split = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let hex = String(line[..<split]).lowercased()
            var name = String(line[line.index(after: split)...])
                .trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard hex.count == 64, hex.unicodeScalars.allSatisfy(isHexDigit), !name.isEmpty else {
                continue
            }
            result[name] = hex
        }
        return result
    }

    /// True when `corveil --version` output reports `tag` (with or without a
    /// leading `v`). Requires a version token, not a prefix of a longer one
    /// (`0.4.3` must not match `0.4.32`).
    public static func verifyMessage(_ message: String, matchesTag tag: String) -> Bool {
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: version)
        let pattern = "(?:^|[^0-9])\(escaped)(?:[^0-9]|$)"
        return message.range(of: pattern, options: .regularExpression) != nil
    }

    /// Drop Gatekeeper quarantine so a GitHub-downloaded darwin binary can
    /// exec. No-op on Linux; failures are ignored (the verify step is the gate).
    public static func clearQuarantine(at path: String) {
        #if os(macOS)
        _ = removexattr(path, "com.apple.quarantine", 0)
        #endif
    }

    /// Keep `current` and one previous version directory; delete the rest.
    /// Only removes directories that look like version installs (contain
    /// `corveil` or a leftover `.partial`). Never touches files it didn't create.
    public static func pruneOldVersions(keeping currentTag: String, managedRoot: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: managedRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        struct VersionDir {
            let url: URL
            let mtime: Date
        }
        var dirs: [VersionDir] = []
        for url in entries {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values?.isDirectory == true else { continue }
            dirs.append(VersionDir(url: url, mtime: values?.contentModificationDate ?? .distantPast))
        }
        let currentName = currentTag
        let others = dirs
            .filter { $0.url.lastPathComponent != currentName }
            .sorted { $0.mtime > $1.mtime }
        // Keep the newest leftover as rollback; drop the rest.
        for stale in others.dropFirst() {
            try? fm.removeItem(at: stale.url)
        }
    }

    private static func isHexDigit(_ scalar: UnicodeScalar) -> Bool {
        (scalar >= "0" && scalar <= "9")
            || (scalar >= "a" && scalar <= "f")
            || (scalar >= "A" && scalar <= "F")
    }
}

/// Outcome of one auto-update check. Failures never throw — the last-good
/// binary stays linked and `message` explains why.
public struct CorveilAutoUpdateStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case disabled
        case skippedOverride = "skipped_override"
        case upToDate = "up_to_date"
        case updated
        case failed
    }

    public var state: State
    public var version: String?
    public var path: String?
    public var message: String?
    public var checkedAtMs: Int64?

    public init(
        state: State,
        version: String? = nil,
        path: String? = nil,
        message: String? = nil,
        checkedAtMs: Int64? = nil
    ) {
        self.state = state
        self.version = version
        self.path = path
        self.message = message
        self.checkedAtMs = checkedAtMs
    }
}
