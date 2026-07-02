import Foundation

/// Helpers for building OpenCode launch commands. Centralized so
/// `OpenCodeAgent`, `OpenCodeLauncher`, and tests share one implementation
/// of the run-then-continue dispatch form and capability probes (#547).
public enum OpenCodeLaunchArgs {
    private static let cacheLock = NSLock()
    /// Guarded by `cacheLock`. Keyed by binary path; not invalidated on in-place
    /// upgrades during a Crow session — acceptable because a wrong answer only
    /// omits an optional flag, never breaks launch.
    private nonisolated(unsafe) static var tuiAutoFlagCache: [String: Bool] = [:]
    private nonisolated(unsafe) static var runHelpCache: [String: String] = [:]

    private static let helpProbeTimeoutSeconds: TimeInterval = 5

    /// POSIX single-quote escape for paths interpolated into shell commands.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether `opencode --help` advertises the TUI `--auto` flag.
    public static func parseTUISupportsAuto(from helpText: String) -> Bool {
        helpText.contains("--auto")
    }

    /// Auto-approve flag for the headless `opencode run` subcommand.
    public static func runAutoApproveSuffix(
        autoPermissionMode: Bool,
        runHelpText: String
    ) -> String {
        guard autoPermissionMode else { return "" }
        if runHelpText.contains("--auto") { return " --auto" }
        if runHelpText.contains("--dangerously-skip-permissions") {
            return " --dangerously-skip-permissions"
        }
        return ""
    }

    /// Probe the installed binary once and cache the result. Only call when
    /// an auto-approve suffix is actually needed — each probe spawns a subprocess.
    public static func tuiSupportsAuto(binary: String) -> Bool {
        cacheLock.lock()
        if let cached = tuiAutoFlagCache[binary] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let help = (try? runHelp(binary: binary, subcommand: nil)) ?? ""
        let supports = parseTUISupportsAuto(from: help)

        cacheLock.lock()
        tuiAutoFlagCache[binary] = supports
        cacheLock.unlock()
        return supports
    }

    /// Cached `opencode run --help` text for the installed binary. Only call
    /// when an auto-approve suffix is actually needed.
    public static func runHelpText(binary: String) -> String {
        cacheLock.lock()
        if let cached = runHelpCache[binary] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let help = (try? runHelp(binary: binary, subcommand: "run")) ?? ""

        cacheLock.lock()
        runHelpCache[binary] = help
        cacheLock.unlock()
        return help
    }

    /// Reset cached probes (tests only).
    internal static func resetCachesForTesting() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        tuiAutoFlagCache.removeAll()
        runHelpCache.removeAll()
    }

    /// TUI auto-approve suffix when the installed build supports `--auto`.
    public static func tuiAutoApproveSuffix(
        autoPermissionMode: Bool,
        tuiSupportsAuto: Bool
    ) -> String {
        guard autoPermissionMode, tuiSupportsAuto else { return "" }
        return " --auto"
    }

    /// First unattended dispatch: headless `run` consumes the prompt file,
    /// then `; opencode --continue` drops into the interactive TUI with a
    /// fresh terminal stdin (not a pipe) so `crow send` keeps working (#547).
    /// Semicolon (not `&&`) so the TUI opens even when `run` exits non-zero,
    /// preserving a resumable session for follow-up input.
    public static func firstLaunchChainedCommand(
        binary: String,
        promptPath: String,
        autoPermissionMode: Bool,
        tuiSupportsAuto: Bool,
        runHelpText: String
    ) -> String {
        let quotedPath = shellQuote(promptPath)
        let runFlags = runAutoApproveSuffix(
            autoPermissionMode: autoPermissionMode,
            runHelpText: runHelpText
        )
        let continueFlags = tuiAutoApproveSuffix(
            autoPermissionMode: autoPermissionMode,
            tuiSupportsAuto: tuiSupportsAuto
        )
        return "\(binary) run \"$(cat \(quotedPath))\"\(runFlags)"
            + "; \(binary) --continue\(continueFlags)\n"
    }

    /// Resume the last OpenCode session in the interactive TUI.
    public static func resumeTUICommand(
        binary: String,
        autoPermissionMode: Bool,
        tuiSupportsAuto: Bool
    ) -> String {
        let flags = tuiAutoApproveSuffix(
            autoPermissionMode: autoPermissionMode,
            tuiSupportsAuto: tuiSupportsAuto
        )
        return "\(binary) --continue\(flags)\n"
    }

    private static func runHelp(binary: String, subcommand: String?) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        if let subcommand {
            process.arguments = [subcommand, "--help"]
        } else {
            process.arguments = ["--help"]
        }
        process.standardOutput = pipe
        process.standardError = pipe

        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + helpProbeTimeoutSeconds,
            execute: timeout
        )
        defer { timeout.cancel() }

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
