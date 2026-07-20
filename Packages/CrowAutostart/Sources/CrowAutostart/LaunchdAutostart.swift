import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// macOS backend: a per-user launchd LaunchAgent at
/// `~/Library/LaunchAgents/com.corveil.crowd.plist`.
///
/// A LaunchAgent (not a system-wide daemon) is the right shape — `crowd` runs
/// as the logged-in user, reads that user's `~/.claude` config and store, and
/// drives that user's tmux. launchd loads every plist in `~/Library/LaunchAgents`
/// at login, so writing the file is what makes "start Crow at login" true; the
/// `launchctl` calls only affect the *current* session.
///
/// Two hazards shape the install logic:
///   - `crowd` refuses to start when another one holds the socket or store
///     lock and `exit(1)`s (`CrowDaemon.run`). So install never bootstraps over
///     a daemon that's already running — it writes the plist and lets the next
///     login pick it up.
///   - For the same reason `KeepAlive` is `{Crashed: true}` rather than
///     `{SuccessfulExit: false}`: a deliberate duplicate-instance `exit(1)` is
///     a *clean* exit, and `SuccessfulExit: false` would respawn it forever.
///     `Crashed` restarts on an actual crash and leaves clean exits alone.
public struct LaunchdAutostart: AutostartService {
    public static let label = "com.corveil.crowd"

    let launchAgentsDirectory: URL
    let logDirectory: URL
    let uid: uid_t
    let runner: CommandRunner
    /// Liveness probe, keyed by the socket the daemon would be listening on.
    /// The socket comes from the spec's `--socket` (the login item registers
    /// one there), so a daemon on a custom socket is detected instead of being
    /// missed and needlessly restarted. `nil` → the well-known default.
    let isDaemonRunning: @Sendable (_ socketPath: String?) -> Bool
    let launchctl: String

    /// `FileManager` is not `Sendable`, so it is reached through the shared
    /// instance rather than stored. Tests isolate themselves with temp
    /// directories (`launchAgentsDirectory` / `logDirectory`), not a fake FS.
    var fileManager: FileManager { .default }

    public init(
        launchAgentsDirectory: URL? = nil,
        logDirectory: URL? = nil,
        uid: uid_t = getuid(),
        runner: @escaping CommandRunner = systemCommandRunner,
        isDaemonRunning: @escaping @Sendable (_ socketPath: String?) -> Bool = { DaemonProbe.isRunning(socketPath: $0) },
        launchctl: String = "/bin/launchctl"
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.launchAgentsDirectory = launchAgentsDirectory ?? home.appendingPathComponent("Library/LaunchAgents")
        self.logDirectory = logDirectory ?? home.appendingPathComponent("Library/Logs/crow")
        self.uid = uid
        self.runner = runner
        self.isDaemonRunning = isDaemonRunning
        self.launchctl = launchctl
    }

    public var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent("\(Self.label).plist")
    }

    public var logURL: URL {
        logDirectory.appendingPathComponent("crowd.log")
    }

    private var domainTarget: String { "gui/\(uid)" }
    private var serviceTarget: String { "gui/\(uid)/\(Self.label)" }

    // MARK: - Install

    public func install(_ spec: AutostartSpec) throws -> AutostartStatus {
        guard CrowdBinaryResolver.isExecutableFile(spec.binaryPath, fileManager: fileManager) else {
            throw AutostartError.binaryNotFound(
                "No executable crowd at \(spec.binaryPath). Build and install it with "
                    + "`make daemon && make install`, or pass --binary.")
        }

        // Probe BEFORE touching launchd: booting out would stop a daemon that's
        // currently serving, and bootstrapping alongside a hand-started one
        // would spawn a duplicate that immediately refuses to run. Probe the
        // socket THIS login item targets, so a daemon on a custom `--socket`
        // isn't missed and needlessly restarted.
        let alreadyRunning = isDaemonRunning(spec.socketPath)

        try createDirectory(launchAgentsDirectory)
        try createDirectory(logDirectory)
        try writePlist(for: spec)

        var notes: [String] = []
        if alreadyRunning {
            // The plist is on disk, so login is covered. Reloading now would
            // either kill the running daemon (if launchd owns it) or spawn a
            // doomed duplicate (if the user started it by hand) — neither is
            // worth doing to a working daemon.
            notes.append("a crowd is already running, so launchd was left alone — the login item takes effect at next login")
        } else {
            // Clear any previous registration first so an upgraded path takes
            // effect in this session too. "not loaded" is the normal case.
            _ = runner(launchctl, ["bootout", serviceTarget])

            let bootstrap = runner(launchctl, ["bootstrap", domainTarget, plistURL.path])
            if !bootstrap.succeeded, !isLoaded() {
                throw AutostartError.commandFailed(
                    command: "launchctl bootstrap \(domainTarget) \(plistURL.path)",
                    status: bootstrap.status,
                    output: bootstrap.output)
            }
            // `RunAtLoad` usually starts it on bootstrap; kickstart makes that
            // deterministic (and covers a re-bootstrap of an already-loaded job).
            let kickstart = runner(launchctl, ["kickstart", "-k", serviceTarget])
            if kickstart.succeeded {
                notes.append("crowd started")
            } else {
                notes.append("registered, but launchd could not start crowd now (\(shortOutput(kickstart))) — check \(logURL.path)")
            }
        }

        var result = try status(expected: spec)
        result.message = (["Autostart enabled (\(Self.label))"] + notes).joined(separator: "; ") + "."
        return result
    }

    // MARK: - Uninstall

    public func uninstall() throws -> AutostartStatus {
        // Best effort: an unloaded service is exactly what we want, so a
        // non-zero bootout ("no such process") is not a failure.
        _ = runner(launchctl, ["bootout", serviceTarget])

        let path = plistURL.path
        let existed = fileManager.fileExists(atPath: path)
        if existed {
            do {
                try fileManager.removeItem(at: plistURL)
            } catch {
                throw AutostartError.writeFailed(path: path, reason: error.localizedDescription)
            }
        }

        var result = try status(expected: nil)
        result.message = existed
            ? "Autostart disabled; removed \(path)."
            : "Autostart was not enabled — nothing to remove."
        return result
    }

    // MARK: - Status

    public func status(expected: AutostartSpec? = nil) throws -> AutostartStatus {
        let installedPath = installedProgramPath()
        // An empty binaryPath (a socket-only status probe) is "no expectation",
        // not a comparison target — otherwise it would read as stale.
        let expectedPath = expected?.binaryPath.isEmpty == true ? nil : expected?.binaryPath
        let enabled = installedPath != nil || fileManager.fileExists(atPath: plistURL.path)
        let stale = {
            guard enabled, let installedPath, let expectedPath else { return false }
            return installedPath != expectedPath
        }()
        let loaded = isLoaded()
        // Probe the socket the login item actually targets (from the installed
        // plist), so a launchd-started daemon on a custom `--socket` is seen;
        // fall back to the caller's expected socket, then the well-known one.
        let running = isDaemonRunning(installedSocketPath() ?? expected?.socketPath)

        var result = AutostartStatus(
            platform: "macos",
            supported: true,
            label: Self.label,
            plistPath: plistURL.path,
            logPath: logURL.path,
            enabled: enabled,
            loaded: loaded,
            running: running,
            installedPath: installedPath,
            expectedPath: expectedPath,
            stale: stale
        )
        result.message = describe(result)
        return result
    }

    private func describe(_ status: AutostartStatus) -> String {
        guard status.enabled else {
            return status.running
                ? "Autostart is off; a crowd is running but will not come back after a reboot."
                : "Autostart is off and no crowd is running. Enable it with `crow autostart install`."
        }
        if status.stale {
            return "Autostart points at \(status.installedPath ?? "an unknown path"), but crowd is at "
                + "\(status.expectedPath ?? "another path"). Re-run `crow autostart install` to re-point it."
        }
        if status.running {
            return "Autostart is on and crowd is running."
        }
        return status.loaded
            ? "Autostart is on and registered with launchd, but crowd is not answering — check \(status.logPath ?? logURL.path)."
            : "Autostart is on; it takes effect at next login (not loaded in this session)."
    }

    // MARK: - launchd / plist plumbing

    /// The registered `ProgramArguments`, or nil when there's no readable plist.
    private func installedProgramArguments() -> [String]? {
        guard let data = fileManager.contents(atPath: plistURL.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any]
        else { return nil }
        return dict["ProgramArguments"] as? [String]
    }

    /// The plist's `ProgramArguments[0]`, or nil when there's no readable plist.
    func installedProgramPath() -> String? {
        installedProgramArguments()?.first
    }

    /// The `--socket` (or `--socket-path`) the login item registered, so status
    /// probes the right socket. Nil when unset — the daemon uses the default.
    func installedSocketPath() -> String? {
        guard let arguments = installedProgramArguments() else { return nil }
        for flag in ["--socket", "--socket-path"] {
            if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    private func isLoaded() -> Bool {
        runner(launchctl, ["print", serviceTarget]).succeeded
    }

    /// XML plist (not binary) so the file stays greppable and diffable — you
    /// can see what Crow registered without `plutil`.
    func plistData(for spec: AutostartSpec) throws -> Data {
        let dict: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": spec.programArguments,
            "RunAtLoad": true,
            // See the type doc: restart on a crash, never on a clean exit —
            // crowd's duplicate-instance refusal is a clean exit(1).
            "KeepAlive": ["Crashed": true],
            "ThrottleInterval": 10,
            "ProcessType": "Background",
            "EnvironmentVariables": ["PATH": loginPath()],
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        } catch {
            throw AutostartError.writeFailed(path: plistURL.path, reason: error.localizedDescription)
        }
    }

    private func writePlist(for spec: AutostartSpec) throws {
        do {
            try plistData(for: spec).write(to: plistURL, options: .atomic)
        } catch let error as AutostartError {
            throw error
        } catch {
            throw AutostartError.writeFailed(path: plistURL.path, reason: error.localizedDescription)
        }
    }

    /// launchd hands agents a bare `PATH`, but `crowd` shells out to `git`,
    /// `gh`, `tmux`, and the agent CLIs. Carry the installing shell's `PATH`
    /// through, with the usual Homebrew/user prefixes appended as a floor.
    private func loginPath() -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let defaults = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        let entries = (current.split(separator: ":").map(String.init) + defaults)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return entries.joined(separator: ":")
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw AutostartError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private func shortOutput(_ result: CommandResult) -> String {
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "exit \(result.status)" : trimmed
    }
}
