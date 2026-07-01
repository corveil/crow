import Foundation

/// Helpers for building OpenCode TUI launch commands. Centralized so
/// `OpenCodeAgent`, `OpenCodeLauncher`, and tests share one implementation
/// of the stdin-pipe seeding form and the `--auto` capability probe (#547).
public enum OpenCodeLaunchArgs {
    private static let cacheLock = NSLock()
    /// Guarded by `cacheLock`.
    private nonisolated(unsafe) static var autoFlagCache: [String: Bool] = [:]

    /// Whether `opencode --help` advertises the TUI `--auto` flag. Older builds
    /// (e.g. 1.17.x) only expose auto-approve on `opencode run`
    /// (`--dangerously-skip-permissions`), which Crow intentionally avoids
    /// because `run` exits to the shell.
    public static func parseTUISupportsAuto(from helpText: String) -> Bool {
        helpText.contains("--auto")
    }

    /// Probe the installed binary once and cache the result.
    public static func tuiSupportsAuto(binary: String) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = autoFlagCache[binary] { return cached }
        let help = (try? runHelp(binary: binary)) ?? ""
        let supports = parseTUISupportsAuto(from: help)
        autoFlagCache[binary] = supports
        return supports
    }

    /// Reset the cached `--auto` probe (tests only).
    internal static func resetAutoFlagCacheForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        autoFlagCache.removeAll()
    }

    /// TUI auto-approve suffix when the installed build supports `--auto`.
    public static func autoApproveSuffix(
        autoPermissionMode: Bool,
        tuiSupportsAuto: Bool
    ) -> String {
        guard autoPermissionMode, tuiSupportsAuto else { return "" }
        return " --auto"
    }

    /// Seed the interactive TUI with a prompt file via stdin pipe. OpenCode's
    /// docs document piping as a supported way to deliver an initial message;
    /// `--prompt` only pre-fills the composer on some builds without
    /// submitting (sst/opencode#3937).
    public static func seededTUICommand(
        binary: String,
        promptPath: String,
        autoPermissionMode: Bool,
        tuiSupportsAuto: Bool
    ) -> String {
        let flags = autoApproveSuffix(
            autoPermissionMode: autoPermissionMode,
            tuiSupportsAuto: tuiSupportsAuto
        )
        return "cat \(promptPath) | \(binary)\(flags)\n"
    }

    /// Resume the last OpenCode session in the interactive TUI.
    public static func resumeTUICommand(
        binary: String,
        autoPermissionMode: Bool,
        tuiSupportsAuto: Bool
    ) -> String {
        let flags = autoApproveSuffix(
            autoPermissionMode: autoPermissionMode,
            tuiSupportsAuto: tuiSupportsAuto
        )
        return "\(binary) --continue\(flags)\n"
    }

    private static func runHelp(binary: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--help"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
