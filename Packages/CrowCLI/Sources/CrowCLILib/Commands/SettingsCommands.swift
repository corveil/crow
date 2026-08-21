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

        --switcher-binding takes a modifier chord like `cmd+/` (the default) or \
        `ctrl+space`, plus one sequence form: a leading `esc` is a prefix, not a \
        modifier, so `esc+tab` means tap Esc, then Tab. A modifier chord commits \
        on release of the modifier; a prefix chord holds nothing down, so the \
        overlay stays open — the key or ←→ cycle, Enter switches, Esc cancels. \
        Esc itself is never swallowed and still reaches the terminal.

        `shift+tab` is rejected: coding agents cycle permission modes with it, \
        and the switcher would swallow that keystroke in every focused terminal. \
        A config still carrying it from an older Crow is migrated to the default \
        on load. On a keyboard with no Cmd, use `ctrl+/`.
        """
    )

    @Option(
        name: .customLong("hide-session-details"),
        help: "Hide ticket title and repo/branch lines in sidebar rows (true or false)")
    var hideSessionDetails: Bool?

    @Option(
        name: .customLong("switcher-enabled"),
        help: "Enable the session switcher overlay (true or false)")
    var switcherEnabled: Bool?

    @Option(
        name: .customLong("switcher-binding"),
        help: "Session switcher key chord (default: cmd+/; shift+tab is reserved by agents)")
    var switcherBinding: String?

    @Option(
        name: .customLong("switcher-capture-in-terminal"),
        help: "Capture the switcher binding inside focused terminals (true or false)")
    var switcherCaptureInTerminal: Bool?

    @Option(
        name: .customLong("switcher-order"),
        help: "Session switcher ordering: mru or sidebar")
    var switcherOrder: String?

    @Option(
        name: .customLong("switcher-preview"),
        help: "Fetch a tmux pane preview for the highlighted switcher card (true or false)")
    var switcherPreview: Bool?

    @Option(
        name: .customLong("switcher-include"),
        parsing: .upToNextOption,
        help: "Include filter as key=value (managers, jobs, reviews, active, paused, in_review, completed, archived)")
    var switcherIncludes: [String] = []

    public init() {}

    public func validate() throws {
        guard hideSessionDetails != nil || switcherEnabled != nil || switcherBinding != nil
            || switcherCaptureInTerminal != nil || switcherOrder != nil || switcherPreview != nil
            || !switcherIncludes.isEmpty else {
            throw ValidationError(
                "Nothing to set — provide at least one UI preference flag.")
        }
        if let switcherOrder, !["mru", "sidebar"].contains(switcherOrder) {
            throw ValidationError("--switcher-order must be mru or sidebar.")
        }
        for item in switcherIncludes {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  ["managers", "jobs", "reviews", "active", "paused", "in_review", "completed", "archived"]
                    .contains(parts[0]),
                  ["true", "false"].contains(parts[1].lowercased()) else {
                throw ValidationError(
                    "--switcher-include must be key=true|false where key is one of: "
                    + "managers, jobs, reviews, active, paused, in_review, completed, archived")
            }
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let hideSessionDetails {
            params["hide_session_details"] = .bool(hideSessionDetails)
        }
        if let switcherEnabled {
            params["switcher_enabled"] = .bool(switcherEnabled)
        }
        if let switcherBinding {
            params["switcher_binding"] = .string(switcherBinding)
        }
        if let switcherCaptureInTerminal {
            params["switcher_capture_in_terminal"] = .bool(switcherCaptureInTerminal)
        }
        if let switcherOrder {
            params["switcher_order"] = .string(switcherOrder)
        }
        if let switcherPreview {
            params["switcher_preview"] = .bool(switcherPreview)
        }
        for item in switcherIncludes {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0]
            let flag = parts[1].lowercased() == "true"
            params["switcher_include_\(key)"] = .bool(flag)
        }
        let result = try rpc("ui-set", params: params)
        printJSON(result)
    }
}

// MARK: - crow terminal

/// Parent command for terminal wheel-scroll tuning: `crow terminal <subcommand>`.
public struct Terminal: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "View or change terminal wheel-scroll speed",
        discussion: """
        Wheel-scroll tuning for the web terminal (CROW-835, ADR 0013). The wheel \
        is routed by surface: plain-shell / review surfaces scroll their own \
        scrollback, so the knob is lines per physical notch; agent TUIs (Claude \
        Code, Cursor, the Manager) own their scrolling, so the knob is how many \
        wheel notches are forwarded to the app per physical notch. Each surface \
        gets its own value.

        These are the two `AppConfig.terminal` fields the web Settings sliders \
        write; this is the CLI half. Not to be confused with the terminal-*tab* \
        verbs (`new-terminal`, `list-terminals`, `send`, …), which manage panes.
        """,
        subcommands: [TerminalGet.self, TerminalSet.self]
    )

    public init() {}
}

public struct TerminalGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get", abstract: "Show the current terminal wheel-scroll settings")

    public init() {}

    public func run() throws {
        let result = try rpc("terminal-get")
        printJSON(result)
    }
}

public struct TerminalSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change terminal wheel-scroll speed",
        discussion: """
        Only the flags you pass change; at least one is required. Connected \
        browsers pick the change up on their next scroll — no reload.

        --wheel-scroll-lines sets scrollback lines per wheel notch on plain-shell \
        and review surfaces (default 3). --agent-wheel-notches sets how many wheel \
        reports are forwarded to the agent per physical notch (default 1 — one \
        detent in, one out; raise it if agent scrolling feels too slow). Both floor \
        at 1: a value of 0 would disable wheel scrolling on that surface.
        """
    )

    @Option(
        name: .customLong("wheel-scroll-lines"),
        help: "Scrollback lines per wheel notch on plain-shell/review surfaces (minimum 1, default 3)")
    var wheelScrollLines: Int?

    @Option(
        name: .customLong("agent-wheel-notches"),
        help: "Wheel notches forwarded to the agent per physical notch (minimum 1, default 1)")
    var agentWheelNotches: Int?

    public init() {}

    public func validate() throws {
        guard wheelScrollLines != nil || agentWheelNotches != nil else {
            throw ValidationError(
                "Nothing to set — provide at least one of --wheel-scroll-lines, --agent-wheel-notches.")
        }
        if let wheelScrollLines { try validateWheelValue(wheelScrollLines, flag: "--wheel-scroll-lines") }
        if let agentWheelNotches { try validateWheelValue(agentWheelNotches, flag: "--agent-wheel-notches") }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let wheelScrollLines { params["wheel_scroll_lines"] = .int(wheelScrollLines) }
        if let agentWheelNotches { params["agent_wheel_notches"] = .int(agentWheelNotches) }
        let result = try rpc("terminal-set", params: params)
        printJSON(result)
    }
}
