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

    // MARK: Spoken notifications (voice spike)
    //
    // A third category beside sound and system notifications: the client speaks
    // a short sentence about what happened ("crow-1078 needs you") through the
    // Web Speech API. Off by default — it is opt-in, and every open client
    // speaks, exactly like chimes.

    /// Global toggle for spoken notifications. Default **false**.
    public var voiceEnabled: Bool

    /// Preferred voice by `SpeechSynthesisVoice.name` (e.g. `Samantha`). `nil`
    /// means the platform default. Voices live in the *client*, so the daemon
    /// can't validate this; a client that doesn't have it falls back to its
    /// default.
    public var voiceName: String?

    /// Speech rate, `SpeechSynthesisUtterance.rate` units (1 = normal).
    public var voiceRate: Double

    /// Speech volume, 0…1.
    public var voiceVolume: Double

    /// When an event both chimes and speaks: true plays the chime first, false
    /// lets the voice *replace* the chime (the default — "a voice instead of a
    /// sound I don't recognize").
    public var chimeBeforeVoice: Bool

    public static let defaultVoiceRate = 1.0
    public static let defaultVoiceVolume = 1.0
    public static let voiceRateRange: ClosedRange<Double> = 0.5...2.0
    public static let voiceVolumeRange: ClosedRange<Double> = 0.0...1.0
    /// Longest stored voice template / voice name, in characters.
    public static let maxVoiceTemplateLength = 200
    public static let maxVoiceNameLength = 100
    /// Placeholders a voice template may use; the client fills them in.
    public static let voicePlaceholders = ["session", "repo", "pr", "event", "title", "body"]

    /// `eventSettings` starts **empty**, not pre-populated with all ten events.
    ///
    /// Absence is the contract: `config(for:)` resolves a missing event to its
    /// current default, so an entry only needs to exist once someone overrides
    /// it. Eagerly materializing the full table looked harmless but wasn't —
    /// every writer that loaded a config with no `notifications` block then
    /// saved all ten entries back, freezing today's `defaultSound` table into
    /// the file and silently opting the user out of future changes to it. A
    /// globals-only `crow notifications set --global-mute` did exactly that
    /// (review of #813).
    public init(
        globalMute: Bool = false,
        soundEnabled: Bool = true,
        systemNotificationsEnabled: Bool = true,
        eventSettings: [NotificationEvent: EventNotificationConfig] = [:],
        voiceEnabled: Bool = false,
        voiceName: String? = nil,
        voiceRate: Double = NotificationSettings.defaultVoiceRate,
        voiceVolume: Double = NotificationSettings.defaultVoiceVolume,
        chimeBeforeVoice: Bool = false
    ) {
        self.globalMute = globalMute
        self.soundEnabled = soundEnabled
        self.systemNotificationsEnabled = systemNotificationsEnabled
        self.eventSettings = eventSettings
        self.voiceEnabled = voiceEnabled
        self.voiceName = voiceName
        self.voiceRate = voiceRate
        self.voiceVolume = voiceVolume
        self.chimeBeforeVoice = chimeBeforeVoice
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
        self.init(
            globalMute: try c.decodeIfPresent(Bool.self, forKey: .globalMute) ?? false,
            soundEnabled: try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true,
            systemNotificationsEnabled: try c.decodeIfPresent(
                Bool.self, forKey: .systemNotificationsEnabled) ?? true,
            // Absent stays absent — see the designated init. A round-trip must
            // not invent entries the file didn't have.
            eventSettings: try c.decodeIfPresent(
                [NotificationEvent: EventNotificationConfig].self, forKey: .eventSettings) ?? [:],
            voiceEnabled: try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? false,
            voiceName: try c.decodeIfPresent(String.self, forKey: .voiceName),
            // Out-of-range numbers are clamped rather than rejected: a hand edit
            // of `voiceRate: 5` must not take the whole config down (CROW-813).
            voiceRate: Self.clamp(
                try c.decodeIfPresent(Double.self, forKey: .voiceRate) ?? Self.defaultVoiceRate,
                to: Self.voiceRateRange),
            voiceVolume: Self.clamp(
                try c.decodeIfPresent(Double.self, forKey: .voiceVolume) ?? Self.defaultVoiceVolume,
                to: Self.voiceVolumeRange),
            chimeBeforeVoice: try c.decodeIfPresent(Bool.self, forKey: .chimeBeforeVoice) ?? false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case globalMute, soundEnabled, systemNotificationsEnabled, eventSettings
        case voiceEnabled, voiceName, voiceRate, voiceVolume, chimeBeforeVoice
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Whether `event` speaks, resolving an absent override to the event's default.
    /// This is the per-event level only; the caller still applies `globalMute`,
    /// `voiceEnabled` and the event's `enabled` master toggle.
    public func voiceEnabled(for event: NotificationEvent) -> Bool {
        eventSettings[event]?.voiceEnabled ?? event.defaultVoiceEnabled
    }

    /// The template `event` speaks, resolving an absent override to the default.
    public func voiceTemplate(for event: NotificationEvent) -> String {
        eventSettings[event]?.voiceTemplate ?? event.defaultVoiceTemplate
    }

    /// Validate a user-supplied voice template. Returns the trimmed template, or
    /// nil for "reset to default" (an empty string). Throws a message on a
    /// template that's too long or contains control characters.
    public static func normalizedVoiceTemplate(_ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.count <= maxVoiceTemplateLength else {
            throw VoiceSettingError("voice template is longer than \(maxVoiceTemplateLength) characters")
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VoiceSettingError("voice template must not contain control characters")
        }
        return trimmed
    }

    /// Validate a voice name. Returns nil for "system default" (an empty string).
    public static func normalizedVoiceName(_ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.count <= maxVoiceNameLength else {
            throw VoiceSettingError("voice name is longer than \(maxVoiceNameLength) characters")
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VoiceSettingError("voice name must not contain control characters")
        }
        return trimmed
    }

    /// Get the config for a specific event, falling back to defaults.
    ///
    /// This ensures forward compatibility: when a new `NotificationEvent` case is added,
    /// existing config files that don't include it in `eventSettings` still get sensible defaults.
    public func config(for event: NotificationEvent) -> EventNotificationConfig {
        eventSettings[event] ?? EventNotificationConfig(soundName: event.defaultSound)
    }

    /// Resolve a user-supplied sound name to its canonical spelling, or nil
    /// when it isn't a built-in and isn't in `customNames`.
    ///
    /// Single source of truth for the `--event-sound-name` rule: the CLI calls it
    /// for fast local feedback and the `notifications-set` handler calls it again
    /// as the authoritative check, so the two can't drift (CROW-813). Matching is
    /// case-insensitive so `crow notifications set --event-sound-name hero` works.
    /// Built-ins win over a custom name that collides (add-sound refuses that
    /// collision, but a dropped file could still create one).
    public static func canonicalSoundName(_ raw: String, customNames: [String] = []) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let builtIn = builtInSounds.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return builtIn
        }
        return customNames.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
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

    /// Sound to play: a built-in name (`Glass`, `Hero`, …) or a custom library
    /// name. Bytes live in Application Support, not here.
    public var soundName: String

    /// Whether this event speaks. `nil` = the event's `defaultVoiceEnabled`.
    ///
    /// Optional on purpose, unlike `soundName`: an entry can't know which event
    /// keys it while decoding (see `init(from:)`), so a concrete default here
    /// would hit the same "partial entry silently becomes Glass" trap. `nil`
    /// stays nil on a round-trip and resolves through
    /// `NotificationSettings.voiceEnabled(for:)`.
    public var voiceEnabled: Bool?

    /// What this event says, with `{session}`-style placeholders. `nil` = the
    /// event's `defaultVoiceTemplate`.
    public var voiceTemplate: String?

    public init(
        enabled: Bool = true,
        soundEnabled: Bool = true,
        systemNotificationEnabled: Bool = true,
        soundName: String = "Glass",
        voiceEnabled: Bool? = nil,
        voiceTemplate: String? = nil
    ) {
        self.enabled = enabled
        self.soundEnabled = soundEnabled
        self.systemNotificationEnabled = systemNotificationEnabled
        self.soundName = soundName
        self.voiceEnabled = voiceEnabled
        self.voiceTemplate = voiceTemplate
    }

    /// Tolerant decode, for the same reason as `NotificationSettings` above: a
    /// hand-edited event entry that names only the field being changed must not
    /// take the whole config down with it.
    ///
    /// - Important: an omitted `soundName` falls back to `"Glass"`, **not** to
    ///   the event's `defaultSound` — decoding one entry has no idea which event
    ///   keys it, since `Dictionary` decodes keys and values separately. So a
    ///   hand-written partial entry for a non-Glass event (`checksFailing`'s
    ///   Sosumi, `autoRebaseConflicts`' Basso) silently becomes Glass. Write
    ///   `soundName` explicitly in a partial entry, or edit through
    ///   `crow notifications set`, which reads the existing entry through
    ///   `config(for:)` and always writes a complete one (review of #813).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        systemNotificationEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .systemNotificationEnabled) ?? true
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? "Glass"
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled)
        voiceTemplate = try c.decodeIfPresent(String.self, forKey: .voiceTemplate)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, soundEnabled, systemNotificationEnabled, soundName
        case voiceEnabled, voiceTemplate
    }
}

/// A rejected voice setting; the message is user-facing.
public struct VoiceSettingError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
