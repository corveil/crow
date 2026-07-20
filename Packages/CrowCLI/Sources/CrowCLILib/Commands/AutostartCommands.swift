import ArgumentParser
import CrowAutostart
import Foundation

// MARK: - Autostart Commands

/// `crow autostart install | uninstall | status` — register `crowd` to start at
/// login (CROW-769).
///
/// Unlike every other subcommand, these run **locally** instead of over the
/// Unix socket. The whole point is to fix "the daemon isn't running", so they
/// have to work with `crowd` down — an RPC would be exactly the wrong
/// dependency. The daemon exposes the same operations over local-only HTTP for
/// the Settings toggle (`AutostartRoutes`), sharing this package's logic.
public struct AutostartCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "autostart",
        abstract: "Start crowd at login (install/uninstall/status)",
        subcommands: [Install.self, Uninstall.self, Status.self],
        defaultSubcommand: Status.self
    )

    public init() {}
}

extension AutostartCommand {
    /// Flags baked into the login item so the login-launched `crowd` comes up
    /// configured the same way you run it by hand. Omitted flags leave the
    /// daemon on its own defaults (`127.0.0.1:8787`, the well-known socket).
    struct DaemonFlags: ParsableArguments {
        @Option(name: .long, help: "Path to the crowd binary (default: next to this crow, then PATH)")
        var binary: String?
        @Option(name: .long, help: "Bind host to pass to crowd (default: crowd's own default)")
        var host: String?
        @Option(name: .long, help: "HTTP port to pass to crowd")
        var port: Int?
        @Option(name: .long, help: "Development root to pass to crowd")
        var devRoot: String?
        @Option(name: .long, help: "Unix socket path to pass to crowd")
        var socket: String?

        func spec() throws -> AutostartSpec {
            AutostartSpec(
                binaryPath: try CrowdBinaryResolver.resolve(override: binary),
                host: host,
                httpPort: port,
                devRoot: devRoot.map { ($0 as NSString).expandingTildeInPath },
                socketPath: socket.map { ($0 as NSString).expandingTildeInPath }
            )
        }
    }

    public struct Install: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Register crowd to start at login (idempotent; re-points after an upgrade)")

        @OptionGroup var daemon: DaemonFlags
        @Flag(name: .long, help: "Print the status as JSON") var json: Bool = false

        public init() {}

        public func run() throws {
            let spec = try daemon.spec()
            let status = try AutostartCommand.service().install(spec)
            emit(status, json: json)
        }
    }

    public struct Uninstall: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Remove the login item (leaves a running crowd alone)")

        @Flag(name: .long, help: "Print the status as JSON") var json: Bool = false

        public init() {}

        public func run() throws {
            emit(try AutostartCommand.service().uninstall(), json: json)
        }
    }

    public struct Status: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report whether crowd is set to start at login, and whether it's running")

        @Option(name: .long, help: "Path to the crowd binary to compare against (stale-plist detection)")
        var binary: String?
        @Flag(name: .long, help: "Print the status as JSON") var json: Bool = false

        public init() {}

        public func run() throws {
            // Status must answer even when no crowd can be found — an
            // unresolvable binary just means no stale comparison.
            let expected = (try? CrowdBinaryResolver.resolve(override: binary)).map { AutostartSpec(binaryPath: $0) }
            emit(try AutostartCommand.service().status(expected: expected), json: json)
        }
    }

    static func service() -> AutostartService { CrowAutostart.Autostart.service() }
}

// MARK: - Output

/// Human-readable by default, `--json` for scripts and the `AutostartStatus`
/// shape the web UI consumes.
private func emit(_ status: AutostartStatus, json: Bool) {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(status), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }

    print(status.message)
    print("  at login: \(status.enabled ? "enabled" : "disabled")")
    print("  running:  \(status.running ? "yes" : "no")")
    if let installedPath = status.installedPath {
        print("  crowd:    \(installedPath)\(status.stale ? "  (stale — reinstall to re-point)" : "")")
    }
    if let plistPath = status.plistPath, status.enabled {
        print("  plist:    \(plistPath)")
    }
    if let logPath = status.logPath, status.enabled {
        print("  log:      \(logPath)")
    }
}
