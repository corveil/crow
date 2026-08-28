import Foundation
import Testing
@testable import CrowCore

@Test func notificationSettingsDefaultInit() {
    let settings = NotificationSettings()

    #expect(settings.globalMute == false)
    #expect(settings.soundEnabled == true)
    #expect(settings.systemNotificationsEnabled == true)

    // No event is materialized up front — absence means "follow the current
    // default", which `config(for:)` resolves on read. Pre-populating the table
    // meant any subsequent save froze today's defaults into the file.
    #expect(settings.eventSettings.isEmpty)
    for event in NotificationEvent.allCases {
        let config = settings.config(for: event)
        #expect(config.enabled == true)
        #expect(config.soundName == event.defaultSound)
    }
}

@Test func notificationSettingsConfigForEventReturnsStored() {
    var settings = NotificationSettings()
    let custom = EventNotificationConfig(enabled: false, soundEnabled: false, systemNotificationEnabled: false, soundName: "Ping")
    settings.eventSettings[.taskComplete] = custom

    let config = settings.config(for: .taskComplete)
    #expect(config.enabled == false)
    #expect(config.soundName == "Ping")
}

@Test func notificationSettingsConfigForEventFallback() {
    // Create settings with empty eventSettings
    let settings = NotificationSettings(eventSettings: [:])
    let config = settings.config(for: .taskComplete)

    // Should fall back to defaults
    #expect(config.enabled == true)
    #expect(config.soundName == NotificationEvent.taskComplete.defaultSound)
}

@Test func notificationSettingsRoundTrip() throws {
    var settings = NotificationSettings(globalMute: true, soundEnabled: false)
    settings.eventSettings[.agentWaiting] = EventNotificationConfig(
        enabled: true,
        soundEnabled: true,
        systemNotificationEnabled: false,
        soundName: "Submarine"
    )

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(NotificationSettings.self, from: data)

    #expect(decoded.globalMute == true)
    #expect(decoded.soundEnabled == false)
    #expect(decoded.eventSettings[.agentWaiting]?.soundName == "Submarine")
    #expect(decoded.eventSettings[.agentWaiting]?.systemNotificationEnabled == false)
}

@Test func notificationSettingsDecodeMinimalJSON() throws {
    // Encode an empty-eventSettings NotificationSettings to get the correct JSON format,
    // since Dictionary<Enum, Value> may encode as an array of key-value pairs.
    let original = NotificationSettings(globalMute: true, eventSettings: [:])
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(NotificationSettings.self, from: data)

    #expect(decoded.globalMute == true)
    #expect(decoded.eventSettings.isEmpty)
    // config(for:) should still return defaults
    let config = decoded.config(for: .taskComplete)
    #expect(config.enabled == true)
}

// MARK: - Decode tolerance (CROW-813)

/// A hand-edited config that names only the field being changed must decode.
/// Before CROW-813 the synthesized `Codable` required all four keys, so this
/// threw `keyNotFound` — which `AppConfig.init(from:)` propagated, making
/// `ConfigStore.loadConfig` return nil and silently reset the *entire* config.
@Test func notificationSettingsDecodesPartialObject() throws {
    let json = #"{"globalMute": true}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(NotificationSettings.self, from: json)

    #expect(decoded.globalMute == true)
    #expect(decoded.soundEnabled == true)
    #expect(decoded.systemNotificationsEnabled == true)
    // eventSettings absent stays absent — decoding must not invent entries the
    // file didn't have, or the next save would persist all ten.
    #expect(decoded.eventSettings.isEmpty)
    #expect(decoded.config(for: .checksFailing).soundName == NotificationEvent.checksFailing.defaultSound)
}

@Test func notificationSettingsDecodesEmptyObject() throws {
    let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data("{}".utf8))

    #expect(decoded.globalMute == false)
    #expect(decoded.soundEnabled == true)
    #expect(decoded.systemNotificationsEnabled == true)
    #expect(decoded.eventSettings.isEmpty)
}

/// The round-trip that made the freeze visible: a config carrying only an
/// override for one event must come back with exactly that one entry.
@Test func notificationSettingsRoundTripDoesNotGrowEventSettings() throws {
    var settings = NotificationSettings()
    settings.eventSettings[.agentWaiting] = EventNotificationConfig(enabled: false, soundName: "Ping")

    let decoded = try JSONDecoder().decode(
        NotificationSettings.self, from: try JSONEncoder().encode(settings))

    #expect(decoded.eventSettings.count == 1)
    #expect(decoded.eventSettings[.agentWaiting]?.soundName == "Ping")
    #expect(decoded.config(for: .checksFailing).soundName == NotificationEvent.checksFailing.defaultSound)
}

/// The `soundName` fallback is `"Glass"`, not the event's default — decoding an
/// entry can't see which event keys it. Pinned so the docs note stays honest.
@Test func eventNotificationConfigPartialDecodeFallsBackToGlassNotEventDefault() throws {
    let json = #"{"enabled": false}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(EventNotificationConfig.self, from: json)

    #expect(decoded.enabled == false)
    #expect(decoded.soundName == "Glass")
    // Explicitly NOT checksFailing's Sosumi, even though that's where a
    // hand-editor would most likely write a partial entry.
    #expect(decoded.soundName != NotificationEvent.checksFailing.defaultSound)
}

/// An explicitly empty `eventSettings` stays empty — only *absence* means
/// "populate the defaults". `config(for:)` covers the read side.
@Test func notificationSettingsDecodePreservesExplicitlyEmptyEventSettings() throws {
    let data = try JSONEncoder().encode(NotificationSettings(eventSettings: [:]))
    let decoded = try JSONDecoder().decode(NotificationSettings.self, from: data)

    #expect(decoded.eventSettings.isEmpty)
}

@Test func eventNotificationConfigDecodesPartialObject() throws {
    let json = #"{"soundName": "Ping"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(EventNotificationConfig.self, from: json)

    #expect(decoded.soundName == "Ping")
    #expect(decoded.enabled == true)
    #expect(decoded.soundEnabled == true)
    #expect(decoded.systemNotificationEnabled == true)
}

// MARK: - canonicalSoundName (CROW-813)

@Test func canonicalSoundNameAcceptsBuiltInSounds() {
    for sound in NotificationSettings.builtInSounds {
        #expect(NotificationSettings.canonicalSoundName(sound) == sound)
    }
}

@Test func canonicalSoundNameIsCaseInsensitiveAndTrims() {
    #expect(NotificationSettings.canonicalSoundName("hero") == "Hero")
    #expect(NotificationSettings.canonicalSoundName("SOSUMI") == "Sosumi")
    #expect(NotificationSettings.canonicalSoundName("  Glass  ") == "Glass")
}

@Test func canonicalSoundNameRejectsUnknownNames() {
    #expect(NotificationSettings.canonicalSoundName("Nope") == nil)
    #expect(NotificationSettings.canonicalSoundName("") == nil)
    #expect(NotificationSettings.canonicalSoundName("/System/Library/Sounds/Glass.aiff") == nil)
}

@Test func canonicalSoundNameAcceptsCustomNames() {
    #expect(NotificationSettings.canonicalSoundName("Office-Bell", customNames: ["Office-Bell"]) == "Office-Bell")
    #expect(NotificationSettings.canonicalSoundName("office-bell", customNames: ["Office-Bell"]) == "Office-Bell")
    #expect(NotificationSettings.canonicalSoundName("Nope", customNames: ["Office-Bell"]) == nil)
    // Built-ins still win when a custom name collides.
    #expect(NotificationSettings.canonicalSoundName("glass", customNames: ["Glass-Custom"]) == "Glass")
}

// MARK: - builtInSounds

@Test func builtInSoundsNonEmpty() {
    #expect(!NotificationSettings.builtInSounds.isEmpty)
    // Default sounds for all events should be in the built-in list
    for event in NotificationEvent.allCases {
        #expect(NotificationSettings.builtInSounds.contains(event.defaultSound),
                "Default sound '\(event.defaultSound)' for \(event) not in builtInSounds")
    }
}

// MARK: - Forward compatibility (CROW-768)

@Test func legacyConfigWithoutAutomationEventsFallsBackToDefaults() throws {
    // A config written before the automation events existed carries only the
    // original five entries. `config(for:)` must still hand back a sensible
    // enabled-by-default config rather than dropping the notification.
    var legacy = NotificationSettings(eventSettings: [:])
    legacy.eventSettings[.taskComplete] = EventNotificationConfig(soundName: "Glass")
    let data = try JSONEncoder().encode(legacy)
    let decoded = try JSONDecoder().decode(NotificationSettings.self, from: data)

    for event in NotificationEvent.allCases where event.isAutomationEvent {
        #expect(decoded.eventSettings[event] == nil)
        let config = decoded.config(for: event)
        #expect(config.enabled == true)
        #expect(config.soundEnabled == true)
        #expect(config.systemNotificationEnabled == true)
        #expect(config.soundName == event.defaultSound)
    }
}
