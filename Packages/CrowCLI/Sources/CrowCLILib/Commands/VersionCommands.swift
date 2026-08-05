import ArgumentParser
import CrowIPC
import Foundation

// MARK: - crow version

/// `crow version` — local build info and upstream comparison (CROW-938).
public struct Version: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show the local build and check for upstream updates",
        discussion: """
        Bare `crow version` prints the stamped build version. Pass `--check` or run \
        `crow version check` to compare against corveil/crow main via the daemon.
        """,
        subcommands: [VersionCheckCmd.self, VersionGet.self, VersionSet.self]
    )

    @Flag(name: .long, help: "Compare this build against corveil/crow main")
    var check: Bool = false

    public init() {}

    public func run() throws {
        if check {
            try VersionCheck.run()
            return
        }
        print(CLIVersion.version)
    }
}

public struct VersionCheckCmd: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Compare this build against corveil/crow main")

    public init() {}

    public func run() throws {
        try VersionCheck.run()
    }
}

/// Shared implementation for `crow version --check` and `crow version check`.
enum VersionCheck {
    static func run() throws {
        let result: [String: JSONValue]
        do {
            result = try rpc("version-update-check", params: ["force": .bool(true)])
        } catch {
            warn("Could not check for updates — is crowd running?")
            throw ExitCode(2)
        }
        guard let status = result["status"], status != .null else {
            warn("Could not check for updates — is crowd running?")
            throw ExitCode(2)
        }
        printHuman(status)
        let state = status.objectValue?["state"]?.stringValue ?? "unknown"
        switch state {
        case "up_to_date": throw ExitCode(0)
        case "behind": throw ExitCode(1)
        default: throw ExitCode(2)
        }
    }

    private static func printHuman(_ status: JSONValue) {
        let obj = status.objectValue ?? [:]
        let version = obj["local_version"]?.stringValue ?? "?"
        let sha = obj["local_sha"]?.stringValue ?? "?"
        let buildDate = obj["build_date"]?.stringValue ?? ""
        var localLine = "crow \(version) (\(sha)"
        if !buildDate.isEmpty { localLine += ", built \(buildDate)" }
        localLine += ")"
        print(localLine)

        let state = obj["state"]?.stringValue ?? "unknown"
        switch state {
        case "up_to_date":
            if let remoteSha = obj["remote_sha"]?.stringValue {
                var remoteLine = "origin/main is at \(remoteSha)"
                if let remoteDate = obj["remote_date"]?.stringValue, !remoteDate.isEmpty {
                    remoteLine += " (\(remoteDate))"
                }
                print(remoteLine)
            }
            print("Up to date.")
        case "behind":
            if let remoteSha = obj["remote_sha"]?.stringValue {
                var remoteLine = "origin/main is at \(remoteSha)"
                if let remoteDate = obj["remote_date"]?.stringValue, !remoteDate.isEmpty {
                    remoteLine += " (\(remoteDate))"
                }
                print(remoteLine)
            }
            if let behind = obj["behind_by"]?.intValue {
                print("→ \(behind) commit\(behind == 1 ? "" : "s") behind")
            }
            if let cmd = obj["update_command"]?.stringValue {
                print("")
                print("Update:  \(cmd)")
            }
        default:
            let reason = obj["reason"]?.stringValue ?? "Could not determine update status"
            print(reason)
        }
    }
}

public struct VersionGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show version-update settings and the cached check result")

    public init() {}

    public func run() throws {
        printJSON(try rpc("version-update-get"))
    }
}

public struct VersionSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change version-update settings",
        discussion: """
        Only the flags you pass change; at least one is required. \
        --interval-hours is floored at 6 so unauthenticated GitHub checks cannot \
        exhaust the 60 req/hr limit.
        """
    )

    @Option(name: .long, help: "Enable periodic upstream checks (true or false)")
    var enabled: Bool?

    @Option(
        name: .customLong("interval-hours"),
        help: "Hours between automatic checks (minimum 6, default 6)")
    var intervalHours: Int?

    public init() {}

    public func validate() throws {
        guard enabled != nil || intervalHours != nil else {
            throw ValidationError(
                "Nothing to set — provide at least one of --enabled, --interval-hours.")
        }
        if let intervalHours, intervalHours < 6 {
            throw ValidationError("--interval-hours must be at least 6.")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let enabled { params["enabled"] = .bool(enabled) }
        if let intervalHours { params["interval_hours"] = .int(intervalHours) }
        printJSON(try rpc("version-update-set", params: params))
    }
}
