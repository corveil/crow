import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

/// Lets `--event` parse straight into the model enum: ArgumentParser derives
/// `init?(argument:)` and `allValueStrings` from the `String` raw value, so the
/// ten valid names appear in `--help` and in the rejection message, and shell
/// completion works — without the CLI keeping its own copy of the event list.
/// (`scripts/check-notification-events.sh` already guards three mirrors of it.)
extension NotificationEvent: @retroactive ExpressibleByArgument {}

/// Parent command for notification settings: `crow notifications <subcommand>`.
///
/// Reads and writes `AppConfig.notifications` — the same subtree the web
/// Settings → Notifications tab edits — over the daemon's RPC socket, so the
/// change lands under the shared config lock and an open web tab picks it up
/// within a couple of seconds (CROW-813).
public struct Notifications: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "notifications",
        abstract: "Read and write notification settings",
        discussion: """
        Notifications cascade: a notification fires only if globalMute is off, \
        the matching global category toggle is on, AND the per-event toggle is \
        on. Global flags apply to every event; the --event-* flags apply to the \
        single event named by --event.
        """,
        subcommands: [NotificationsGet.self, NotificationsSet.self]
    )

    public init() {}
}

public struct NotificationsGet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show notification settings",
        discussion: """
        Lists the global toggles, every event's effective settings, and the \
        built-in sound names. Events absent from config.json are reported with \
        the defaults they will actually fire with. --event narrows the event \
        list to one entry; the global toggles are always included, since they \
        can be the reason an event never fires.
        """
    )

    @Option(name: .long, help: "Restrict the event list to one event")
    var event: NotificationEvent?

    public init() {}

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let event { params["event"] = .string(event.rawValue) }
        let result = try rpc("notifications-get", params: params)
        printJSON(result)
    }
}

public struct NotificationsSet: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change notification settings",
        discussion: """
        Only the provided flags change; everything else keeps its value. Each \
        toggle takes a --flag / --no-flag pair. The --event-* flags require \
        --event and apply to that event alone. --event-sound-name accepts the \
        built-in sounds listed by `crow notifications get` (case-insensitive).
        """
    )

    // Global toggles. `Bool?` + .prefixedNo gives three states — true, false,
    // and "flag absent, leave the stored value alone". `.exclusive` rejects
    // `--x --no-x`, which the default `.chooseLast` would silently accept.
    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Master mute — suppresses every sound and system notification")
    var globalMute: Bool?
    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Global sound-playback toggle")
    var soundEnabled: Bool?
    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Global system-notification toggle")
    var systemNotificationsEnabled: Bool?

    // Per-event settings, all scoped by --event.
    @Option(name: .long, help: "Event to change (required by every --event-* flag)")
    var event: NotificationEvent?
    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Whether this event notifies at all")
    var eventEnabled: Bool?
    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Whether this event plays a sound")
    var eventSoundEnabled: Bool?
    @Flag(inversion: .prefixedNo, exclusivity: .exclusive,
          help: "Whether this event posts a system notification")
    var eventSystemNotificationEnabled: Bool?
    @Option(name: .customLong("event-sound-name"), help: "Sound for this event (a built-in sound name)")
    var eventSoundName: String?

    public init() {}

    private var hasEventField: Bool {
        eventEnabled != nil || eventSoundEnabled != nil
            || eventSystemNotificationEnabled != nil || eventSoundName != nil
    }

    private var hasGlobalField: Bool {
        globalMute != nil || soundEnabled != nil || systemNotificationsEnabled != nil
    }

    public func validate() throws {
        // Scope checks first: with only `--event`, both `has*Field` are false, so
        // the generic "nothing to set" would fire and bury the real mistake.
        if event == nil, hasEventField {
            throw ValidationError("--event is required when using any --event-* flag.")
        }
        if event != nil, !hasEventField {
            throw ValidationError("--event given with nothing to change — provide at least one --event-* flag.")
        }
        guard hasGlobalField || hasEventField else {
            throw ValidationError("Nothing to set — provide at least one setting flag.")
        }
        if let eventSoundName { try validateNotificationSound(eventSoundName) }
    }

    public func run() throws {
        var params: [String: JSONValue] = [:]
        if let globalMute { params["global_mute"] = .bool(globalMute) }
        if let soundEnabled { params["sound_enabled"] = .bool(soundEnabled) }
        if let systemNotificationsEnabled {
            params["system_notifications_enabled"] = .bool(systemNotificationsEnabled)
        }
        if let event { params["event"] = .string(event.rawValue) }
        if let eventEnabled { params["event_enabled"] = .bool(eventEnabled) }
        if let eventSoundEnabled { params["event_sound_enabled"] = .bool(eventSoundEnabled) }
        if let eventSystemNotificationEnabled {
            params["event_system_notification_enabled"] = .bool(eventSystemNotificationEnabled)
        }
        // Sent raw — the handler canonicalizes casing through the same
        // `NotificationSettings.canonicalSoundName` this command validated with,
        // so the RPC stays self-sufficient for non-CLI callers.
        if let eventSoundName { params["event_sound_name"] = .string(eventSoundName) }
        let result = try rpc("notifications-set", params: params)
        printJSON(result)
    }
}
