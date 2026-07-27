import Foundation

/// Notification preferences stored in AppConfig.
///
/// Notifications follow a cascading disable model:
/// 1. `globalMute` overrides everything — no sounds or system notifications.
/// 2. `soundEnabled` / `systemNotificationsEnabled` act as global category toggles.
/// 3. Per-event settings in `eventSettings` provide fine-grained control.
///
/// A notification only fires if the global toggle, the category toggle, **and** the
/// per-event toggle are all enabled.
public struct NotificationSettings: Codable, Sendable, Equatable {
    /// Available built-in macOS system sounds.
    public static let builtInSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Ping", "Pop",
        "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Master mute — suppresses all sounds and system notifications.
    public var globalMute: Bool

    /// Global toggle for sound playback.
    public var soundEnabled: Bool

    /// Global toggle for macOS notification center alerts.
    public var systemNotificationsEnabled: Bool

    /// Per-event-category configuration.
    public var eventSettings: [NotificationEvent: EventNotificationConfig]

    public init(
        globalMute: Bool = false,
        soundEnabled: Bool = true,
        systemNotificationsEnabled: Bool = true,
        eventSettings: [NotificationEvent: EventNotificationConfig]? = nil
    ) {
        self.globalMute = globalMute
        self.soundEnabled = soundEnabled
        self.systemNotificationsEnabled = systemNotificationsEnabled
        if let eventSettings {
            self.eventSettings = eventSettings
        } else {
            // Populate defaults for all event categories
            var defaults: [NotificationEvent: EventNotificationConfig] = [:]
            for event in NotificationEvent.allCases {
                defaults[event] = EventNotificationConfig(soundName: event.defaultSound)
            }
            self.eventSettings = defaults
        }
    }

    /// Tolerant decode: every key is optional and falls back to its default.
    ///
    /// The synthesized `Codable` required all four keys, so a hand-edited
    /// `{"notifications": {"globalMute": true}}` threw `keyNotFound` — and since
    /// `AppConfig.init(from:)` decodes this subtree with a throwing
    /// `decodeIfPresent`, the failure propagated out and `ConfigStore.loadConfig`
    /// returned nil, silently degrading the *entire* config to defaults. Mirrors
    /// `TerminalSettings` / `AutoRespondSettings` (CROW-813).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let events = try c.decodeIfPresent(
            [NotificationEvent: EventNotificationConfig].self, forKey: .eventSettings)
        // Delegating to the designated init keeps the "nil → populate all events
        // with their defaults" rule in one place.
        self.init(
            globalMute: try c.decodeIfPresent(Bool.self, forKey: .globalMute) ?? false,
            soundEnabled: try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true,
            systemNotificationsEnabled: try c.decodeIfPresent(
                Bool.self, forKey: .systemNotificationsEnabled) ?? true,
            eventSettings: events
        )
    }

    private enum CodingKeys: String, CodingKey {
        case globalMute, soundEnabled, systemNotificationsEnabled, eventSettings
    }

    /// Get the config for a specific event, falling back to defaults.
    ///
    /// This ensures forward compatibility: when a new `NotificationEvent` case is added,
    /// existing config files that don't include it in `eventSettings` still get sensible defaults.
    public func config(for event: NotificationEvent) -> EventNotificationConfig {
        eventSettings[event] ?? EventNotificationConfig(soundName: event.defaultSound)
    }

    /// Resolve a user-supplied sound name to its canonical `builtInSounds`
    /// spelling, or nil when it isn't a built-in sound.
    ///
    /// Single source of truth for the `--event-sound-name` rule: the CLI calls it
    /// for fast local feedback and the `notifications-set` handler calls it again
    /// as the authoritative check, so the two can't drift (CROW-813). Matching is
    /// case-insensitive so `crow notifications set --event-sound-name hero` works.
    public static func canonicalSoundName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return builtInSounds.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
}

/// Per-event notification configuration.
public struct EventNotificationConfig: Codable, Sendable, Equatable {
    /// Whether this event category triggers any notification at all.
    public var enabled: Bool

    /// Whether to play a sound for this event.
    public var soundEnabled: Bool

    /// Whether to post a macOS system notification.
    public var systemNotificationEnabled: Bool

    /// Name of the sound to play (macOS system sound name or path to custom file).
    public var soundName: String

    public init(
        enabled: Bool = true,
        soundEnabled: Bool = true,
        systemNotificationEnabled: Bool = true,
        soundName: String = "Glass"
    ) {
        self.enabled = enabled
        self.soundEnabled = soundEnabled
        self.systemNotificationEnabled = systemNotificationEnabled
        self.soundName = soundName
    }

    /// Tolerant decode, for the same reason as `NotificationSettings` above: a
    /// hand-edited event entry that names only the field being changed must not
    /// take the whole config down with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        systemNotificationEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .systemNotificationEnabled) ?? true
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? "Glass"
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, soundEnabled, systemNotificationEnabled, soundName
    }
}
