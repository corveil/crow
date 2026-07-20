import Foundation
import Testing
@testable import CrowCore

@Test func notificationSettingsDefaultInit() {
    let settings = NotificationSettings()

    #expect(settings.globalMute == false)
    #expect(settings.soundEnabled == true)
    #expect(settings.systemNotificationsEnabled == true)

    // Every event case should have an entry
    for event in NotificationEvent.allCases {
        #expect(settings.eventSettings[event] != nil)
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
