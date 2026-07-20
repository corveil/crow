import Foundation

/// Registering `crowd` to start at login (CROW-769).
///
/// ADR-0010 retired the macOS app, which used to launch at login and bring its
/// daemon with it. `crowd` had no equivalent, so after a reboot Crow simply
/// wasn't running until the user started it by hand. This package closes that
/// gap behind a platform-neutral protocol: macOS gets a launchd LaunchAgent
/// today, and the Linux daemon effort (#645) can add a `systemctl --user` unit
/// without reshaping the API or the `crow autostart` CLI surface.
public protocol AutostartService: Sendable {
    /// Register (or re-point) the login item and report the resulting state.
    /// Idempotent: installing twice leaves exactly one registration.
    func install(_ spec: AutostartSpec) throws -> AutostartStatus

    /// Remove the login item. A missing registration is success, not an error.
    func uninstall() throws -> AutostartStatus

    /// Report the current state without changing anything.
    ///
    /// - Parameter expected: the `crowd` this machine *should* be launching, if
    ///   known. Supplying it enables stale detection (a plist left pointing at
    ///   a binary that moved). `nil` when the caller can't resolve one.
    func status(expected: AutostartSpec?) throws -> AutostartStatus
}

// MARK: - Spec

/// What to launch at login: the `crowd` binary plus the flags it should carry.
///
/// The flags mirror `DaemonOptions` so the login-item daemon comes up
/// configured exactly like the one the user is already running.
public struct AutostartSpec: Sendable, Equatable {
    public var binaryPath: String
    public var host: String?
    public var httpPort: Int?
    public var devRoot: String?
    public var socketPath: String?

    public init(
        binaryPath: String,
        host: String? = nil,
        httpPort: Int? = nil,
        devRoot: String? = nil,
        socketPath: String? = nil
    ) {
        self.binaryPath = binaryPath
        self.host = host
        self.httpPort = httpPort
        self.devRoot = devRoot
        self.socketPath = socketPath
    }

    /// The full argv the login item runs — `ProgramArguments` on macOS.
    public var programArguments: [String] {
        var args = [binaryPath]
        if let host { args += ["--host", host] }
        if let httpPort { args += ["--http-port", String(httpPort)] }
        if let devRoot { args += ["--dev-root", devRoot] }
        if let socketPath { args += ["--socket", socketPath] }
        return args
    }
}

// MARK: - Status

/// A snapshot of the login item, shaped for both `crow autostart status --json`
/// and the Settings → General toggle. `Codable` so both render the same fields.
public struct AutostartStatus: Codable, Sendable, Equatable {
    /// `"macos"` / `"linux"` — which backend answered.
    public var platform: String
    /// False when the platform has no backend yet (see `UnsupportedAutostart`).
    public var supported: Bool
    /// Service identifier (launchd label / systemd unit name).
    public var label: String
    /// Where the registration lives on disk, when the backend uses a file.
    public var plistPath: String?
    /// Where the daemon's stdout/stderr are captured.
    public var logPath: String?
    /// A registration exists — "start Crow at login" is on.
    public var enabled: Bool
    /// The init system currently knows about the service (loaded this session).
    public var loaded: Bool
    /// A `crowd` is answering on the socket right now.
    public var running: Bool
    /// The binary the registration actually points at.
    public var installedPath: String?
    /// The binary it *should* point at, when the caller could resolve one.
    public var expectedPath: String?
    /// The registration points somewhere other than `expectedPath` — a stale
    /// plist left behind by a move or reinstall. Reinstall to re-point.
    public var stale: Bool
    /// Human-readable summary; the CLI prints it, the web UI shows it inline.
    public var message: String

    public init(
        platform: String,
        supported: Bool,
        label: String,
        plistPath: String? = nil,
        logPath: String? = nil,
        enabled: Bool = false,
        loaded: Bool = false,
        running: Bool = false,
        installedPath: String? = nil,
        expectedPath: String? = nil,
        stale: Bool = false,
        message: String = ""
    ) {
        self.platform = platform
        self.supported = supported
        self.label = label
        self.plistPath = plistPath
        self.logPath = logPath
        self.enabled = enabled
        self.loaded = loaded
        self.running = running
        self.installedPath = installedPath
        self.expectedPath = expectedPath
        self.stale = stale
        self.message = message
    }
}

// MARK: - Errors

public enum AutostartError: Error, LocalizedError, Equatable {
    case unsupportedPlatform(String)
    case binaryNotFound(String)
    case commandFailed(command: String, status: Int32, output: String)
    case writeFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform(let detail):
            return detail
        case .binaryNotFound(let detail):
            return detail
        case .commandFailed(let command, let status, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "`\(command)` failed (exit \(status))\(trimmed.isEmpty ? "" : ": \(trimmed)")"
        case .writeFailed(let path, let reason):
            return "Failed to write \(path): \(reason)"
        }
    }
}

// MARK: - Command runner

/// Result of a shelled-out command: exit status plus combined output.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    public var succeeded: Bool { status == 0 }
}

/// Runs an external command. Injected so tests exercise the install/uninstall
/// logic without ever spawning `launchctl`.
public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> CommandResult

/// The real runner: spawns the executable and captures its combined output.
public let systemCommandRunner: CommandRunner = { executable, arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return CommandResult(status: -1, output: "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Factory

public enum Autostart {
    /// The backend for the host platform. macOS → launchd LaunchAgent; anything
    /// else → an `UnsupportedAutostart` that reports cleanly instead of failing
    /// obscurely, until #645 adds the systemd `--user` backend.
    public static func service() -> AutostartService {
        #if os(macOS)
        return LaunchdAutostart()
        #else
        return UnsupportedAutostart()
        #endif
    }
}

/// Placeholder backend for platforms with no installer yet. Every call reports
/// `supported: false` rather than pretending to have registered something.
public struct UnsupportedAutostart: AutostartService {
    private let platform: String

    public init(platform: String = UnsupportedAutostart.hostPlatform) {
        self.platform = platform
    }

    public static var hostPlatform: String {
        #if os(Linux)
        return "linux"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    private var explanation: String {
        "Autostart is not supported on \(platform) yet — start crowd yourself (a terminal, tmux, "
            + "or your own systemd --user unit). Tracking: https://github.com/corveil/crow/issues/645"
    }

    public func install(_ spec: AutostartSpec) throws -> AutostartStatus {
        throw AutostartError.unsupportedPlatform(explanation)
    }

    public func uninstall() throws -> AutostartStatus {
        throw AutostartError.unsupportedPlatform(explanation)
    }

    public func status(expected: AutostartSpec?) throws -> AutostartStatus {
        AutostartStatus(
            platform: platform,
            supported: false,
            label: LaunchdAutostart.label,
            expectedPath: expected?.binaryPath,
            message: explanation
        )
    }
}
