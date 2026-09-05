import Foundation

/// Linux backend: a systemd `--user` unit at
/// `~/.config/systemd/user/com.corveil.crowd.service`.
///
/// A user unit (not a system-wide service) is the right shape — `crowd` runs
/// as the logged-in user, reads that user's config and store, and drives that
/// user's tmux. `WantedBy=default.target` starts it with the user session, so
/// `systemctl --user enable` is what makes "start Crow at login" true; the
/// `start` call only affects the *current* session.
///
/// Two hazards shape the install logic, matching ``LaunchdAutostart``:
///   - `crowd` refuses to start when another one holds the socket or store
///     lock and `exit(1)`s (`CrowDaemon.run`). So install never
///     `systemctl --user start`s over a daemon that's already running — it
///     writes the unit, `daemon-reload`s, and `enable`s so the next login
///     picks it up.
///   - For the same reason `Restart=` is `on-abnormal` rather than
///     `on-failure` / `always`: a deliberate duplicate-instance `exit(1)` is
///     a *clean* non-zero exit, and `on-failure` would respawn it forever.
///     `on-abnormal` restarts on a crash, uncaught signal, or watchdog
///     timeout, and leaves clean exits alone.
public struct SystemdAutostart: AutostartService {
    /// Same identifier as the launchd label, with a `.service` suffix on disk.
    public static let label = "com.corveil.crowd"
    public static let unitName = "\(label).service"

    let unitsDirectory: URL
    let logDirectory: URL
    let runner: CommandRunner
    /// Liveness probe, keyed by the socket the daemon would be listening on.
    /// The socket comes from the spec's `--socket` (the unit registers one
    /// there), so a daemon on a custom socket is detected instead of being
    /// missed and needlessly restarted. `nil` → the well-known default.
    let isDaemonRunning: @Sendable (_ socketPath: String?) -> Bool
    let systemctl: String

    /// `FileManager` is not `Sendable`, so it is reached through the shared
    /// instance rather than stored. Tests isolate themselves with temp
    /// directories (`unitsDirectory` / `logDirectory`), not a fake FS.
    var fileManager: FileManager { .default }

    public init(
        unitsDirectory: URL? = nil,
        logDirectory: URL? = nil,
        runner: @escaping CommandRunner = systemCommandRunner,
        isDaemonRunning: @escaping @Sendable (_ socketPath: String?) -> Bool = { DaemonProbe.isRunning(socketPath: $0) },
        systemctl: String = "/usr/bin/systemctl"
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        self.unitsDirectory = unitsDirectory
            ?? Self.defaultUnitsDirectory(home: home, environment: environment)
        self.logDirectory = logDirectory
            ?? Self.defaultLogDirectory(home: home, environment: environment)
        self.runner = runner
        self.isDaemonRunning = isDaemonRunning
        self.systemctl = systemctl
    }

    public var unitURL: URL {
        unitsDirectory.appendingPathComponent(Self.unitName)
    }

    public var logURL: URL {
        logDirectory.appendingPathComponent("crowd.log")
    }

    /// `$XDG_CONFIG_HOME/systemd/user`, falling back to `~/.config/systemd/user`.
    /// An empty `XDG_CONFIG_HOME` is treated as unset (XDG spec).
    static func defaultUnitsDirectory(home: URL, environment: [String: String]) -> URL {
        configHome(home: home, environment: environment)
            .appendingPathComponent("systemd/user")
    }

    /// `$XDG_STATE_HOME/crow`, falling back to `~/.local/state/crow`.
    /// An empty `XDG_STATE_HOME` is treated as unset (XDG spec).
    static func defaultLogDirectory(home: URL, environment: [String: String]) -> URL {
        stateHome(home: home, environment: environment)
            .appendingPathComponent("crow")
    }

    private static func configHome(home: URL, environment: [String: String]) -> URL {
        nonEmpty(environment["XDG_CONFIG_HOME"]).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
    }

    private static func stateHome(home: URL, environment: [String: String]) -> URL {
        nonEmpty(environment["XDG_STATE_HOME"]).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/state")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Install

    public func install(_ spec: AutostartSpec) throws -> AutostartStatus {
        guard CrowdBinaryResolver.isExecutableFile(spec.binaryPath, fileManager: fileManager) else {
            throw AutostartError.binaryNotFound(
                "No executable crowd at \(spec.binaryPath). Build and install it with "
                    + "`make daemon && make install`, or pass --binary.")
        }

        // Probe BEFORE touching systemd: starting would spawn a duplicate that
        // immediately refuses to run (single-instance + store-writer locks),
        // and restarting would kill a daemon that's currently serving. Probe
        // the socket THIS unit targets, so a daemon on a custom `--socket`
        // isn't missed and needlessly restarted.
        let alreadyRunning = isDaemonRunning(spec.socketPath)

        try createDirectory(unitsDirectory)
        try createDirectory(logDirectory)
        try writeUnit(for: spec)

        var notes: [String] = []
        try runOrThrow("daemon-reload", "systemctl --user daemon-reload")

        // `enable` (no `--now`) covers the next login without starting a
        // process. Always do this — writing the unit file alone is not
        // enough; systemd only starts enabled user units.
        let enable = systemctlUser("enable", Self.unitName)
        if !enable.succeeded {
            throw AutostartError.commandFailed(
                command: "systemctl --user enable \(Self.unitName)",
                status: enable.status,
                output: enable.output)
        }

        if alreadyRunning {
            notes.append("a crowd is already running, so systemd was not started — the unit takes effect at next login")
        } else {
            let start = systemctlUser("start", Self.unitName)
            if start.succeeded {
                notes.append("crowd started")
            } else {
                notes.append("registered, but systemd could not start crowd now (\(shortOutput(start))) — check \(logURL.path)")
            }
        }

        var result = try status(expected: spec)
        result.message = (["Autostart enabled (\(Self.label))"] + notes).joined(separator: "; ") + "."
        return result
    }

    // MARK: - Uninstall

    public func uninstall() throws -> AutostartStatus {
        // Best effort: a disabled unit is exactly what we want, so a
        // non-zero disable ("not loaded") is not a failure. `--now` stops a
        // systemd-owned crowd the way launchd `bootout` does; a hand-started
        // crowd is not a unit, so it is left alone.
        _ = systemctlUser("disable", "--now", Self.unitName)

        let path = unitURL.path
        let existed = fileManager.fileExists(atPath: path)
        if existed {
            do {
                try fileManager.removeItem(at: unitURL)
            } catch {
                throw AutostartError.writeFailed(path: path, reason: error.localizedDescription)
            }
        }

        _ = systemctlUser("daemon-reload")

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
        let enabled = installedPath != nil || fileManager.fileExists(atPath: unitURL.path)
        let stale = {
            guard enabled, let installedPath, let expectedPath else { return false }
            return installedPath != expectedPath
        }()
        let loaded = isEnabledWithSystemd()
        // Probe the socket the unit actually targets (from the installed
        // file), so a systemd-started daemon on a custom `--socket` is seen;
        // fall back to the caller's expected socket, then the well-known one.
        let running = isDaemonRunning(installedSocketPath() ?? expected?.socketPath)

        var result = AutostartStatus(
            platform: "linux",
            supported: true,
            label: Self.label,
            plistPath: unitURL.path,
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
            ? "Autostart is on and registered with systemd, but crowd is not answering — check \(status.logPath ?? logURL.path)."
            : "Autostart is on; it takes effect at next login (not loaded in this session)."
    }

    // MARK: - systemd / unit plumbing

    /// The registered `ExecStart` argv, or nil when there's no readable unit.
    private func installedProgramArguments() -> [String]? {
        guard let data = fileManager.contents(atPath: unitURL.path),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("ExecStart=") else { continue }
            let raw = String(trimmed.dropFirst("ExecStart=".count))
            let arguments = Self.parseExecArguments(raw)
            return arguments.isEmpty ? nil : arguments
        }
        return nil
    }

    /// The unit's `ExecStart` binary, or nil when there's no readable unit.
    func installedProgramPath() -> String? {
        installedProgramArguments()?.first
    }

    /// The `--socket` (or `--socket-path`) the unit registered, so status
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

    private func isEnabledWithSystemd() -> Bool {
        systemctlUser("is-enabled", Self.unitName).succeeded
    }

    /// systemd unit file (not a drop-in) so the file stays greppable and
    /// diffable — you can see what Crow registered without `systemctl cat`.
    func unitText(for spec: AutostartSpec) -> String {
        let exec = spec.programArguments.map(Self.quote).joined(separator: " ")
        let path = Self.quote("PATH=\(loginPath())")
        let logCapture = Self.quote("append:\(logURL.path)")
        return """
        # Managed by `crow autostart`. Rewritten on every install.
        [Unit]
        Description=Crow daemon (crowd)
        Documentation=https://github.com/corveil/crow

        [Service]
        Type=simple
        ExecStart=\(exec)
        Restart=on-abnormal
        RestartSec=10
        Environment=\(path)
        StandardOutput=\(logCapture)
        StandardError=\(logCapture)

        [Install]
        WantedBy=default.target

        """
    }

    private func writeUnit(for spec: AutostartSpec) throws {
        do {
            try unitText(for: spec).write(to: unitURL, atomically: true, encoding: .utf8)
        } catch {
            throw AutostartError.writeFailed(path: unitURL.path, reason: error.localizedDescription)
        }
    }

    /// systemd `--user` units get a thin `PATH`, but `crowd` shells out to
    /// `git`, `gh`/`glab`, `tmux`, and the agent CLIs. Carry the installing
    /// shell's `PATH` through, with the usual user/system prefixes appended
    /// as a floor.
    private func loginPath() -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let defaults = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
            "/home/linuxbrew/.linuxbrew/bin",
            "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        var seen = Set<String>()
        let entries = (current.split(separator: ":").map(String.init) + defaults)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return entries.joined(separator: ":")
    }

    /// C-style quoting plus systemd specifier escaping, so a path with spaces
    /// or `%` survives `ExecStart=` / `Environment=` / `StandardOutput=`.
    static func quote(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        escaped = escaped.replacingOccurrences(of: "$", with: "\\$")
        escaped = escaped.replacingOccurrences(of: "%", with: "%%")
        return "\"\(escaped)\""
    }

    /// Inverse of ``quote`` over a whitespace-separated `ExecStart=` rest.
    static func parseExecArguments(_ rest: String) -> [String] {
        var tokens: [String] = []
        var index = rest.startIndex
        while index < rest.endIndex {
            if rest[index].isWhitespace {
                index = rest.index(after: index)
                continue
            }
            if rest[index] == "\"" {
                var token = ""
                index = rest.index(after: index)
                while index < rest.endIndex {
                    let character = rest[index]
                    if character == "\\" {
                        let next = rest.index(after: index)
                        guard next < rest.endIndex else { break }
                        token.append(rest[next])
                        index = rest.index(after: next)
                        continue
                    }
                    if character == "\"" {
                        index = rest.index(after: index)
                        break
                    }
                    token.append(character)
                    index = rest.index(after: index)
                }
                tokens.append(token.replacingOccurrences(of: "%%", with: "%"))
            } else {
                let start = index
                while index < rest.endIndex && !rest[index].isWhitespace {
                    index = rest.index(after: index)
                }
                tokens.append(String(rest[start..<index]).replacingOccurrences(of: "%%", with: "%"))
            }
        }
        return tokens
    }

    private func systemctlUser(_ arguments: String...) -> CommandResult {
        runner(systemctl, ["--user"] + arguments)
    }

    private func runOrThrow(_ verb: String, _ command: String) throws {
        let result = systemctlUser(verb)
        if !result.succeeded {
            throw AutostartError.commandFailed(
                command: command,
                status: result.status,
                output: result.output)
        }
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
