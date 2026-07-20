import Foundation

/// Durable, greppable log file for background-automation decisions (CROW-782).
///
/// The daemon's own `log()` writes to stderr, and `IssueTracker` `NSLog`s only
/// when it *acts* — so when auto-merge silently skipped every PR there was
/// nothing left to read afterwards. This sink gives each poll's automation
/// decisions (including the skips and their reasons) a stable file that
/// survives daemon restarts and stderr redirection:
///
///     ~/Library/Logs/crow/crowd-automation.log
///
/// Lines are `<ISO8601> [automation] <message>` and are also mirrored to
/// `NSLog`, so existing Console-based debugging keeps working unchanged.
///
/// Writes are serialized with an `NSLock` (same approach as `JSONStore`) and
/// the file is size-capped: past `maxBytes` it rotates to `…log.1`, keeping
/// exactly one previous generation, so a long-lived daemon can't fill the disk.
///
/// Per ADR 0012, a test process never writes to the live log directory — the
/// default directory resolves to a per-process temp dir under a test runner.
public enum CrowLog {
    /// Rotate once the active file exceeds this size (bytes).
    static let maxBytes: Int = 5 * 1024 * 1024

    private static let lock = NSLock()
    /// `nonisolated(unsafe)`: only ever touched while holding `lock`.
    private nonisolated(unsafe) static var overrideDirectory: URL?

    /// `nonisolated(unsafe)`: only ever used while holding `lock`.
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Point the sink at a different directory. Tests use this to write into a
    /// temp dir; production leaves it alone.
    public static func configure(directory: URL?) {
        lock.lock()
        overrideDirectory = directory
        lock.unlock()
    }

    /// Directory holding the automation log. `~/Library/Logs/crow` in
    /// production; a temp directory under a test runner (ADR 0012).
    public static var directory: URL {
        lock.lock()
        defer { lock.unlock() }
        return resolvedDirectoryLocked()
    }

    /// Full path of the active automation log file.
    public static var fileURL: URL { directory.appendingPathComponent("crowd-automation.log") }

    /// Append one automation line, and mirror it to `NSLog`.
    public static func automation(_ message: String) {
        NSLog("[Crow][automation] %@", message as NSString)
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        appendLocked("\(timestampFormatter.string(from: now)) [automation] \(message)\n")
    }

    // MARK: - Internals (all callers hold `lock`)

    private static func resolvedDirectoryLocked() -> URL {
        if let overrideDirectory { return overrideDirectory }
        if isRunningUnderTests() {
            // Never write into the developer's real log directory from a test
            // process (ADR 0012). Appending is not destructive the way a
            // full-store `mutate` is, but test noise in a diagnostic log is
            // exactly what makes the log untrustworthy later.
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("crow-test-logs-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/crow", isDirectory: true)
    }

    private static func appendLocked(_ line: String) {
        let dir = resolvedDirectoryLocked()
        let url = dir.appendingPathComponent("crowd-automation.log")
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        rotateIfNeededLocked(url: url)

        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write (or the file was removed under us) — create it.
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func rotateIfNeededLocked(url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let rotated = url.appendingPathExtension("1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    /// Mirrors `JSONStore.isRunningUnderTests()` — see ADR 0012 for why each
    /// signal is checked. Duplicated rather than shared because `CrowCore` sits
    /// below `CrowPersistence` in the package graph.
    private static func isRunningUnderTests() -> Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        let arg0 = CommandLine.arguments.first
        let runnerNames: Set<String> = ["swiftpm-testing-helper", "xctest"]
        if let base = (arg0 as NSString?)?.lastPathComponent, runnerNames.contains(base) { return true }
        if runnerNames.contains(ProcessInfo.processInfo.processName) { return true }
        if arg0?.contains(".xctest") == true { return true }
        return false
    }
}
