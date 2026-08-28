import ArgumentParser
import Foundation
import Testing
import CrowCore
@testable import CrowCLILib

// MARK: - `crow notifications` command parsing (CROW-813)

@Test func notificationsGroupRoutesToSubcommands() throws {
    // The nested `crow notifications <sub>` group resolves each verb to its type.
    let get = try Notifications.parseAsRoot(["get"])
    #expect(get is NotificationsGet)
    let set = try Notifications.parseAsRoot(["set", "--global-mute"])
    #expect(set is NotificationsSet)
    let wav = try writeTempWav()
    defer { try? FileManager.default.removeItem(at: wav) }
    let add = try Notifications.parseAsRoot(["add-sound", wav.path])
    #expect(add is NotificationsAddSound)
    let remove = try Notifications.parseAsRoot(["remove-sound", "Office-Bell"])
    #expect(remove is NotificationsRemoveSound)
}

/// A tiny on-disk .wav so `add-sound` parse can satisfy `validate()` (existence
/// + extension). Magic bytes are the daemon's job.
private func writeTempWav() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crow-cli-sound-\(UUID().uuidString).wav")
    try Data("RIFF".utf8).write(to: url) // contents unused at parse time
    // Pad so it's not empty; extension is what validate checks.
    var data = Data("RIFF".utf8)
    data.append(Data(repeating: 0, count: 12))
    try data.write(to: url)
    return url
}

// MARK: - get

@Test func notificationsGetParsesWithoutFlags() throws {
    let cmd = try NotificationsGet.parse([])
    #expect(cmd.event == nil)
}

@Test func notificationsGetParsesEvent() throws {
    let cmd = try NotificationsGet.parse(["--event", "checksFailing"])
    #expect(cmd.event == .checksFailing)
}

/// `--event` parses straight into the model enum, so every case is accepted and
/// the CLI never carries its own copy of the event list.
@Test func notificationsGetAcceptsEveryEventCase() throws {
    for event in NotificationEvent.allCases {
        let cmd = try NotificationsGet.parse(["--event", event.rawValue])
        #expect(cmd.event == event)
    }
}

@Test func notificationsGetRejectsUnknownEvent() {
    #expect(throws: (any Error).self) { _ = try NotificationsGet.parse(["--event", "nope"]) }
}

// MARK: - set: globals

@Test func notificationsSetParsesGlobalTogglesOn() throws {
    let cmd = try NotificationsSet.parse([
        "--global-mute", "--sound-enabled", "--system-notifications-enabled",
    ])
    #expect(cmd.globalMute == true)
    #expect(cmd.soundEnabled == true)
    #expect(cmd.systemNotificationsEnabled == true)
    try cmd.validate()
}

@Test func notificationsSetParsesGlobalTogglesOff() throws {
    let cmd = try NotificationsSet.parse([
        "--no-global-mute", "--no-sound-enabled", "--no-system-notifications-enabled",
    ])
    #expect(cmd.globalMute == false)
    #expect(cmd.soundEnabled == false)
    #expect(cmd.systemNotificationsEnabled == false)
    try cmd.validate()
}

/// An omitted toggle stays nil so the handler leaves the stored value alone —
/// the whole reason these are `Bool?` rather than `Bool = false`.
@Test func notificationsSetLeavesOmittedTogglesNil() throws {
    let cmd = try NotificationsSet.parse(["--global-mute"])
    #expect(cmd.globalMute == true)
    #expect(cmd.soundEnabled == nil)
    #expect(cmd.systemNotificationsEnabled == nil)
    #expect(cmd.event == nil)
    try cmd.validate()
}

/// `.exclusive` — the default `.chooseLast` would silently take the last one.
@Test func notificationsSetRejectsContradictoryToggle() {
    #expect(throws: (any Error).self) {
        _ = try NotificationsSet.parse(["--global-mute", "--no-global-mute"])
    }
}

// MARK: - set: per-event

@Test func notificationsSetParsesEventFields() throws {
    let cmd = try NotificationsSet.parse([
        "--event", "taskComplete",
        "--no-event-enabled",
        "--event-sound-enabled",
        "--no-event-system-notification-enabled",
        "--event-sound-name", "Hero",
    ])
    #expect(cmd.event == .taskComplete)
    #expect(cmd.eventEnabled == false)
    #expect(cmd.eventSoundEnabled == true)
    #expect(cmd.eventSystemNotificationEnabled == false)
    #expect(cmd.eventSoundName == "Hero")
    try cmd.validate()
}

@Test func notificationsSetAcceptsGlobalAndEventFieldsTogether() throws {
    let cmd = try NotificationsSet.parse([
        "--global-mute", "--event", "agentWaiting", "--event-sound-name", "Ping",
    ])
    try cmd.validate()
}

@Test func notificationsSetAcceptsSoundNameCaseInsensitively() throws {
    let cmd = try NotificationsSet.parse([
        "--event", "taskComplete", "--event-sound-name", "hero",
    ])
    // Canonicalization happens server-side; the CLI only has to accept it.
    try cmd.validate()
}

// MARK: - set: rejections

@Test func notificationsSetRejectsNoFlags() {
    #expect(throws: (any Error).self) {
        let cmd = try NotificationsSet.parse([])
        try cmd.validate()
    }
}

@Test func notificationsSetRejectsEventFieldWithoutEvent() {
    for args in [
        ["--event-enabled"],
        ["--no-event-sound-enabled"],
        ["--event-system-notification-enabled"],
        ["--event-sound-name", "Glass"],
    ] {
        #expect(throws: (any Error).self) {
            let cmd = try NotificationsSet.parse(args)
            try cmd.validate()
        }
    }
}

@Test func notificationsSetRejectsEventWithoutAnyEventField() {
    // `--event` alone leaves both field groups empty, so the scope check has to
    // run before the generic "nothing to set" guard — otherwise it buries the
    // real mistake behind a message that never mentions --event.
    #expect(setParseError(["--event", "taskComplete"]).contains("--event-*"))
    // …including when only global flags accompany it — those don't scope to the event.
    #expect(setParseError(["--global-mute", "--event", "taskComplete"]).contains("--event-*"))
    // The no-flags case still gets the generic message.
    #expect(setParseError([]).contains("Nothing to set"))
}

/// The message a user actually sees on stderr, for asserting we point at the
/// right flag rather than merely throwing something. `parse` runs `validate`,
/// so the rejection surfaces here.
private func setParseError(_ args: [String]) -> String {
    do {
        _ = try NotificationsSet.parse(args)
        return ""
    } catch {
        return String(describing: error)
    }
}

@Test func notificationsSetRejectsUnknownSound() {
    #expect(throws: (any Error).self) {
        let cmd = try NotificationsSet.parse([
            "--event", "taskComplete", "--event-sound-name", "Nope",
        ])
        try cmd.validate()
    }
    // A custom file path is a valid stored value but not a settable one.
    #expect(throws: (any Error).self) {
        let cmd = try NotificationsSet.parse([
            "--event", "taskComplete", "--event-sound-name", "/System/Library/Sounds/Glass.aiff",
        ])
        try cmd.validate()
    }
}

@Test func notificationsSetRejectsUnknownEvent() {
    #expect(throws: (any Error).self) {
        _ = try NotificationsSet.parse(["--event", "nope", "--event-enabled"])
    }
}

// MARK: - validateNotificationSound

@Test func validateNotificationSoundAcceptsEveryBuiltIn() throws {
    for sound in NotificationSettings.builtInSounds {
        try validateNotificationSound(sound)
    }
}

@Test func validateNotificationSoundRejectsUnknown() {
    #expect(throws: (any Error).self) { try validateNotificationSound("Nope", customNames: []) }
    #expect(throws: (any Error).self) { try validateNotificationSound("", customNames: []) }
}

@Test func validateNotificationSoundAcceptsCustomNames() throws {
    try validateNotificationSound("Office-Bell", customNames: ["Office-Bell"])
    try validateNotificationSound("office-bell", customNames: ["Office-Bell"])
}

// MARK: - add-sound / remove-sound

@Test func notificationsAddSoundParsesPathAndName() throws {
    let wav = try writeTempWav()
    defer { try? FileManager.default.removeItem(at: wav) }
    let cmd = try NotificationsAddSound.parse([wav.path, "--name", "Office Bell"])
    #expect(cmd.path == wav.path)
    #expect(cmd.name == "Office Bell")
}

@Test func notificationsAddSoundRejectsMissingFile() {
    #expect(throws: (any Error).self) {
        _ = try NotificationsAddSound.parse(["/no/such/crow-sound.wav"])
    }
}

@Test func notificationsAddSoundRejectsUnsupportedExtension() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("crow-cli-sound-\(UUID().uuidString).txt")
    try Data("x".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: (any Error).self) {
        _ = try NotificationsAddSound.parse([url.path])
    }
}

@Test func notificationsRemoveSoundParsesName() throws {
    let cmd = try NotificationsRemoveSound.parse(["Office-Bell"])
    #expect(cmd.name == "Office-Bell")
}
