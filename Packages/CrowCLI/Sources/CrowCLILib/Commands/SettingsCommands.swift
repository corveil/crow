import ArgumentParser
import CrowIPC
import Foundation

// General-tab settings groups: `crow telemetry`, `crow cleanup`, `crow ui`
// (CROW-814). Each maps to one `AppConfig` subtree and follows the `crow job`
// shape — a noun parent with bare `get` / `set` verbs.
//
// Every `set` is a PATCH: only the flags you pass change, and passing none is an
// error rather than a silent no-op (a no-op would still rewrite config.json and
// fire a spurious "Config reloaded" notification in every open browser).
//
// Booleans are `@Option ... Bool?` rather than `@Flag`, because a patch needs
// three states — true, false, and "not provided". The cost is that ArgumentParser
// parses `Bool` through `LosslessStringConvertible`, which accepts *only* the
// literals `true` and `false`; hence the explicit "(true or false)" in each help
// string.

// MARK: - crow telemetry

/// Parent command for telemetry settings: `crow telemetry <subcommand>`.
public struct Telemetry: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "telemetry",
        abstract: "View or change session-analytics collection",
        subcommands: [TelemetryGet.self, TelemetrySet.self]
    )

    public init() {}
}

public struct TelemetryGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Show the current telemetry settings")

    public init() {}

    public func run() throws {
        let result = try rpc("telemetry-get")
        printJSON(result)
    }
}

public struct TelemetrySet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change telemetry settings",
        discussion: """
        Only the flags you pass change; at least one is required.

        --enabled and --port are read once when crowd starts, and the port is \
        baked into every agent launch's OTEL_EXPORTER_OTLP_ENDPOINT, so changing \
        either returns "restart_required": true — restart crowd to apply it. \
        --retention-days drives the prune that runs at startup, so it likewise \
        applies at the next daemon start.
        """
    )

    @Option(name: .long, help: "Enable the OTLP receiver (true or false)")
    var enabled: Bool?

    @Option(name: .long, help: "OTLP HTTP receiver port (1024-65535, default 4318)")
    var port: Int?

    @Option(
        name: .customLong("retention-days"),
        help: "Days of telemetry to keep; 0 keeps forever (default 180)")
    var retentionDays: Int?

    public init() {}

    public func validate() throws {
        guard enabled != nil || port != nil || retentionDays != nil else {
            throw ValidationError(
                "Nothing to set — provide at least one of --enabled, --port, --retention-days.")
        }
        if let port { try validateTelemetryPort(port) }
        if let retentionDays { try validateRetentionDays(retentionDays) }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let enabled { params["enabled"] = .bool(enabled) }
        if let port { params["port"] = .int(port) }
        if let retentionDays { params["retention_days"] = .int(retentionDays) }
        let result = try rpc("telemetry-set", params: params)
        printJSON(result)
        // stdout stays pure JSON (every command's contract); the nudge goes to
        // stderr so an interactive user doesn't miss an inert write.
        if result["restart_required"]?.boolValue == true {
            warn("telemetry enabled/port changed — restart crowd for it to take effect.")
        }
    }
}

// MARK: - crow cleanup

/// Parent command for session auto-cleanup settings: `crow cleanup <subcommand>`.
public struct Cleanup: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "cleanup",
        abstract: "View or change automatic session cleanup",
        subcommands: [CleanupGet.self, CleanupSet.self]
    )

    public init() {}
}

public struct CleanupGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Show the current cleanup settings")

    public init() {}

    public func run() throws {
        let result = try rpc("cleanup-get")
        printJSON(result)
    }
}

public struct CleanupSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change automatic session cleanup",
        discussion: """
        Only the flags you pass change; at least one is required.

        Auto-cleanup deletes completed and archived sessions after the retention \
        period, including their worktree and branch. Manager, virtual, and locked \
        sessions are never deleted.

        This setting is live: the board poll re-reads it from disk each cycle, so \
        enabling it starts deleting eligible sessions within about a minute. No \
        restart, and no confirmation prompt.
        """
    )

    @Option(name: .long, help: "Enable auto-cleanup (true or false)")
    var enabled: Bool?

    @Option(
        name: .customLong("retention-hours"),
        help: "Hours to keep completed/archived sessions (minimum 1, default 24)")
    var retentionHours: Int?

    public init() {}

    public func validate() throws {
        guard enabled != nil || retentionHours != nil else {
            throw ValidationError(
                "Nothing to set — provide at least one of --enabled, --retention-hours.")
        }
        if let retentionHours { try validateRetentionHours(retentionHours) }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let enabled { params["enabled"] = .bool(enabled) }
        if let retentionHours { params["retention_hours"] = .int(retentionHours) }
        let result = try rpc("cleanup-set", params: params)
        printJSON(result)
    }
}

// MARK: - crow ui

/// Parent command for UI display preferences: `crow ui <subcommand>`.
public struct UI: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ui",
        abstract: "View or change UI display preferences",
        discussion: """
        Display preferences only — this does not start, stop, or open the web UI.

        Settings are grouped by the config block they belong to, so `get` returns \
        {"ui": {"sidebar": {...}}} and gains further blocks as more view options \
        become configurable.
        """,
        subcommands: [UIGet.self, UISet.self]
    )

    public init() {}
}

public struct UIGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Show the current UI display preferences")

    public init() {}

    public func run() throws {
        let result = try rpc("ui-get")
        printJSON(result)
    }
}

public struct UISet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change UI display preferences",
        discussion: """
        Only the flags you pass change; at least one is required. Connected \
        browsers pick the change up within a couple of seconds — no reload.
        """
    )

    @Option(
        name: .customLong("hide-session-details"),
        help: "Hide ticket title and repo/branch lines in sidebar rows (true or false)")
    var hideSessionDetails: Bool?

    public init() {}

    public func validate() throws {
        guard hideSessionDetails != nil else {
            throw ValidationError("Nothing to set — provide --hide-session-details.")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let hideSessionDetails {
            params["hide_session_details"] = .bool(hideSessionDetails)
        }
        let result = try rpc("ui-set", params: params)
        printJSON(result)
    }
}
