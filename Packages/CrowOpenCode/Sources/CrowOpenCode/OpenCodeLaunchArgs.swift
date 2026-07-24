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
    private nonisolated(unsafe) static var versionCache: [String: SemVer?] = [:]

    private static let helpProbeTimeoutSeconds: TimeInterval = 5

    /// The first `opencode` release that re-added the top-level TUI `--auto`
    /// flag. It was present pre-`1.17`, **removed across the `1.17.x` window**,
    /// then re-added in `1.18.0` (2026-07-14; verified `sst/opencode`
    /// `tui.ts@v1.18.4`). Only within `[tuiAutoRemovedVersion,
    /// tuiAutoReintroducedVersion)` can the TUI `--help` probe for `--auto`
    /// answer only "no" — so we short-circuit it there (CROW-831). Outside that
    /// window we still probe, so a *future* upstream flip is caught without a
    /// code change.
    static let tuiAutoReintroducedVersion = SemVer(1, 18, 0)

    /// The first `1.17.x` release where the top-level TUI `--auto` flag was
    /// dropped. Below this (`< 1.17`) the flag was still present, so the probe
    /// must run — do **not** treat those builds as "known absent".
    static let tuiAutoRemovedVersion = SemVer(1, 17, 0)

    /// A parsed `MAJOR.MINOR.PATCH`, compared field-by-field.
    struct SemVer: Comparable, Equatable {
        let major, minor, patch: Int
        init(_ major: Int, _ minor: Int, _ patch: Int) {
            self.major = major; self.minor = minor; self.patch = patch
        }
        static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// Parse the leading `MAJOR.MINOR.PATCH` out of `opencode --version` output
    /// (e.g. `"1.17.10"`, or `"opencode 1.18.4"`). Returns `nil` when no such
    /// triple is present, in which case callers must fall back to probing.
    static func parseVersion(_ text: String) -> SemVer? {
        // First run of `digits.digits.digits` anywhere in the string.
        guard let range = text.range(
            of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        let parts = text[range].split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return SemVer(parts[0], parts[1], parts[2])
    }

    /// Whether a known installed `version` falls in the window where the TUI
    /// `--auto` flag was dropped — `[1.17.0, 1.18.0)` — so the top-level
    /// `--auto` probe is guaranteed to miss and can be skipped. Builds `<1.17`
    /// still had the flag and `≥1.18` re-added it, so both fall through to the
    /// probe; a `nil` version is "unknown" and never skipped.
    static func tuiAutoKnownAbsent(version: SemVer?) -> Bool {
        guard let version else { return false }
        return version >= tuiAutoRemovedVersion && version < tuiAutoReintroducedVersion
    }

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
    ///
    /// Version-narrowed (CROW-831): on builds older than
    /// `tuiAutoReintroducedVersion` the TUI `--auto` flag is *known absent*, so
    /// we answer `false` from the (cheaper) `--version` string alone and skip
    /// the dead-weight `opencode --help` parse. On `≥1.18` and on unparseable
    /// versions we still run the `--help` probe, so an upstream flip is caught
    /// without a code change (the probe was never wrong on `≥1.18`).
    public static func tuiSupportsAuto(binary: String) -> Bool {
        cacheLock.lock()
        if let cached = tuiAutoFlagCache[binary] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let supports: Bool
        if tuiAutoKnownAbsent(version: installedVersion(binary: binary)) {
            // Known `<1.18`: the top-level `--auto` flag does not exist. No point
            // spawning `opencode --help` to confirm the absence.
            supports = false
        } else {
            let help = (try? runHelp(binary: binary, subcommand: nil)) ?? ""
            supports = parseTUISupportsAuto(from: help)
        }

        cacheLock.lock()
        tuiAutoFlagCache[binary] = supports
        cacheLock.unlock()
        return supports
    }

    /// Cached parsed `opencode --version` for the installed binary. Returns
    /// `nil` (and caches it) when the binary can't be run or its output has no
    /// `MAJOR.MINOR.PATCH` — callers then fall back to the `--help` probe.
    static func installedVersion(binary: String) -> SemVer? {
        cacheLock.lock()
        if let cached = versionCache[binary] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let version = (try? runHelp(binary: binary, subcommand: nil, versionOnly: true))
            .flatMap { parseVersion($0) }

        cacheLock.lock()
        versionCache[binary] = version
        cacheLock.unlock()
        return version
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
        versionCache.removeAll()
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

    private static func runHelp(
        binary: String,
        subcommand: String?,
        versionOnly: Bool = false
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        if versionOnly {
            process.arguments = ["--version"]
        } else if let subcommand {
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
