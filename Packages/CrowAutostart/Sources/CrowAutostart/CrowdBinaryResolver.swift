import Foundation

/// Works out which `crowd` the login item should launch.
///
/// Order: an explicit override → a `crowd` sitting next to the calling
/// executable (`make install` symlinks `crow` and `crowd` into the same
/// `~/.local/bin`) → `PATH`.
///
/// Symlinks are deliberately **not** resolved. `make install` points
/// `~/.local/bin/crowd` at `.build/<config>/crowd`, so the symlink is the
/// stable path — it keeps working across rebuilds and debug/release switches,
/// while the resolved target would pin the plist to one build directory. Pass
/// an explicit path when you want the real binary registered instead.
public enum CrowdBinaryResolver {
    /// - Parameters:
    ///   - override: an explicit path (the CLI's `--binary`), used verbatim.
    ///   - siblingOf: an executable whose directory to search — normally the
    ///     running `crow`/`crowd` (`Bundle.main.executableURL`).
    /// - Throws: `AutostartError.binaryNotFound` when nothing usable turns up.
    public static func resolve(
        override: String? = nil,
        siblingOf executable: URL? = Bundle.main.executableURL,
        fileManager: FileManager = .default,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) throws -> String {
        if let override {
            let expanded = (override as NSString).expandingTildeInPath
            guard isExecutableFile(expanded, fileManager: fileManager) else {
                throw AutostartError.binaryNotFound(
                    "No executable crowd at \(expanded). Pass --binary with the path to your crowd.")
            }
            return absolute(expanded)
        }

        if let executable {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("crowd").path
            if isExecutableFile(sibling, fileManager: fileManager) {
                return sibling
            }
        }

        for directory in (pathEnvironment ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(directory) as NSString).appendingPathComponent("crowd")
            if isExecutableFile(candidate, fileManager: fileManager) {
                return absolute(candidate)
            }
        }

        throw AutostartError.binaryNotFound(
            "Could not find a crowd binary next to this executable or on PATH. "
                + "Build and install it with `make daemon && make install`, or pass --binary.")
    }

    /// Executable *file* — a directory named `crowd` is reported executable by
    /// `isExecutableFile` (that's the search bit), so check the type too.
    static func isExecutableFile(_ path: String, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    private static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
