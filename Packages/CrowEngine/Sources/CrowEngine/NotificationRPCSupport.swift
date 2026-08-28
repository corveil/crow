import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `notifications-*` RPC handlers (CROW-813).
///
/// Kept out of the router so the param validation and response shapes are
/// unit-testable without a socket (same pattern as `JobRPC`).
public enum NotificationRPC {
    /// Decode a `NotificationEvent` raw value (`"taskComplete"`, …).
    ///
    /// - Throws: `RPCError.invalidParams` when missing or not one of the cases,
    ///   listing every valid value so the caller doesn't have to guess.
    public static func decodeEvent(_ value: JSONValue?) throws -> NotificationEvent {
        guard let raw = value?.stringValue else {
            throw RPCError.invalidParams("event required (one of: \(allEventNames))")
        }
        guard let event = NotificationEvent(rawValue: raw) else {
            throw RPCError.invalidParams("'\(raw)' is not a notification event. Expected one of: \(allEventNames)")
        }
        return event
    }

    /// Resolve a sound name to its canonical built-in spelling, or to a custom
    /// library name from `customNames`.
    ///
    /// Write-side only — `settingsJSON` echoes a stored `soundName` untouched,
    /// including a path leftover from before custom sounds were a first-class
    /// library, so a missing file never fails a read.
    ///
    /// - Throws: `RPCError.invalidParams` listing built-ins (and custom names
    ///   when any exist) when unmatched.
    public static func decodeSoundName(
        _ value: JSONValue?,
        customNames: [String] = []
    ) throws -> String {
        guard let raw = value?.stringValue else {
            throw RPCError.invalidParams("event_sound_name must be a string")
        }
        guard let canonical = NotificationSettings.canonicalSoundName(raw, customNames: customNames) else {
            let extras = customNames.isEmpty
                ? ""
                : "; custom: \(customNames.joined(separator: ", "))"
            throw RPCError.invalidParams(
                "'\(raw)' is not an available sound. Expected one of: \(NotificationSettings.builtInSounds.joined(separator: ", "))\(extras)"
            )
        }
        return canonical
    }

    /// One custom-sound record as RPC JSON (`name` / `file` / `url`).
    public static func customSoundJSON(_ sound: CustomSound) -> JSONValue {
        .object([
            "name": .string(sound.name),
            "file": .string(sound.file),
            "url": .string(sound.url),
        ])
    }

    /// Canonical notification-settings JSON for RPC responses: snake_case
    /// globals, plus an `events` **object** keyed by event raw value.
    ///
    /// Built by hand rather than by encoding `NotificationSettings`, because
    /// `NotificationEvent` isn't `CodingKeyRepresentable` — `JSONEncoder` writes
    /// `eventSettings` as a flat alternating `[key, value, key, value, …]` array,
    /// which is fine on disk but hostile to `jq`.
    ///
    /// Every event is listed, resolved through `config(for:)`, so an event absent
    /// from `config.json` still reports the defaults it will actually fire with.
    ///
    /// - Parameters:
    ///   - only: restrict `events` to a single event. The globals are always
    ///     included — otherwise a caller can't see that `global_mute` is the
    ///     reason nothing fires.
    ///   - configReadable: false when `config.json` exists but couldn't be
    ///     decoded, so the caller knows these are fabricated defaults rather than
    ///     their real settings.
    public static func settingsJSON(
        _ settings: NotificationSettings,
        only: NotificationEvent? = nil,
        configReadable: Bool = true,
        customSounds: [CustomSound] = []
    ) -> JSONValue {
        let events = only.map { [$0] } ?? NotificationEvent.allCases
        var eventsObject: [String: JSONValue] = [:]
        for event in events {
            let config = settings.config(for: event)
            eventsObject[event.rawValue] = .object([
                "enabled": .bool(config.enabled),
                "sound_enabled": .bool(config.soundEnabled),
                "system_notification_enabled": .bool(config.systemNotificationEnabled),
                "sound_name": .string(config.soundName),
            ])
        }
        let available = NotificationSettings.builtInSounds.map { JSONValue.string($0) }
            + customSounds.map { .string($0.name) }
        return .object([
            "global_mute": .bool(settings.globalMute),
            "sound_enabled": .bool(settings.soundEnabled),
            "system_notifications_enabled": .bool(settings.systemNotificationsEnabled),
            "events": .object(eventsObject),
            "available_sounds": .array(available),
            "custom_sounds": .array(customSounds.map(customSoundJSON)),
            "config_readable": .bool(configReadable),
        ])
    }

    /// Every event raw value, for error messages.
    private static var allEventNames: String {
        NotificationEvent.allCases.map(\.rawValue).joined(separator: ", ")
    }
}
