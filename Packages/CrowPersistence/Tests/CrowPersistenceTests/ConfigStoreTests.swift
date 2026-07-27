import Foundation
import Testing
@testable import CrowPersistence
@testable import CrowCore

@Test func configStoreRoundTrip() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = AppConfig(
        workspaces: [WorkspaceInfo(name: "TestOrg")],
        defaults: ConfigDefaults(branchPrefix: "fix/"),
        notifications: NotificationSettings(globalMute: true),
        sidebar: SidebarSettings(hideSessionDetails: true),
        remoteControlEnabled: true
    )

    try ConfigStore.saveConfig(config, to: claudeDir)

    let configURL = claudeDir.appendingPathComponent("config.json")
    let loaded = ConfigStore.loadConfig(from: configURL)

    #expect(loaded != nil)
    #expect(loaded?.workspaces.count == 1)
    #expect(loaded?.workspaces.first?.name == "TestOrg")
    #expect(loaded?.defaults.branchPrefix == "fix/")
    #expect(loaded?.notifications.globalMute == true)
    #expect(loaded?.sidebar.hideSessionDetails == true)
    #expect(loaded?.remoteControlEnabled == true)
}

@Test func configStoreForwardCompatDefaultsRemoteControlOff() throws {
    // A config.json written by an older Crow build won't include `remoteControlEnabled`.
    // Decoding must succeed and default the flag to false.
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let configURL = tmpDir.appendingPathComponent("config.json")
    // Minimal pre-existing config with no remoteControlEnabled key. All top-level
    // fields on AppConfig use decodeIfPresent, so an empty object is sufficient.
    try "{}".write(to: configURL, atomically: true, encoding: .utf8)

    let loaded = ConfigStore.loadConfig(from: configURL)
    #expect(loaded != nil)
    #expect(loaded?.remoteControlEnabled == false)
    // Legacy configs should opt in to auto permission mode by default so the
    // Manager benefits without requiring users to re-save settings.
    #expect(loaded?.managerAutoPermissionMode == true)
    // Coder views are the opposite: default to plan mode unless the user
    // explicitly opts in (#586).
    #expect(loaded?.coderViewAutoPermissionMode == false)
}

@Test func configStoreCoderViewAutoPermissionModeRoundTrip() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    var config = AppConfig()
    config.coderViewAutoPermissionMode = true
    try ConfigStore.saveConfig(config, to: claudeDir)

    let configURL = claudeDir.appendingPathComponent("config.json")
    let loaded = ConfigStore.loadConfig(from: configURL)
    #expect(loaded?.coderViewAutoPermissionMode == true)
}

@Test func configStoreManagerAutoPermissionModeRoundTrip() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    var config = AppConfig()
    config.managerAutoPermissionMode = false
    try ConfigStore.saveConfig(config, to: claudeDir)

    let configURL = claudeDir.appendingPathComponent("config.json")
    let loaded = ConfigStore.loadConfig(from: configURL)
    #expect(loaded?.managerAutoPermissionMode == false)
}

@Test func configStoreLoadMissingFileReturnsNil() {
    let missingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    let result = ConfigStore.loadConfig(from: missingURL)
    #expect(result == nil)
}

@Test func configStoreLoadMalformedJSONReturnsNil() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let configURL = tmpDir.appendingPathComponent("config.json")
    try "not valid json {{{".write(to: configURL, atomically: true, encoding: .utf8)

    let result = ConfigStore.loadConfig(from: configURL)
    #expect(result == nil)
}

@Test func configStoreSaveCreatesDirectory() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    #expect(!FileManager.default.fileExists(atPath: claudeDir.path))

    try ConfigStore.saveConfig(AppConfig(), to: claudeDir)

    #expect(FileManager.default.fileExists(atPath: claudeDir.path))
    let configURL = claudeDir.appendingPathComponent("config.json")
    #expect(FileManager.default.fileExists(atPath: configURL.path))
}

@Test func configStoreSaveSetsPermissions() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    try ConfigStore.saveConfig(AppConfig(), to: claudeDir)

    let configURL = claudeDir.appendingPathComponent("config.json")

    // Check file permissions (0o600 = owner read/write only)
    let fileAttrs = try FileManager.default.attributesOfItem(atPath: configURL.path)
    let filePerms = fileAttrs[.posixPermissions] as? Int
    #expect(filePerms == 0o600)

    // Check directory permissions (0o700 = owner read/write/execute only)
    let dirAttrs = try FileManager.default.attributesOfItem(atPath: claudeDir.path)
    let dirPerms = dirAttrs[.posixPermissions] as? Int
    #expect(dirPerms == 0o700)
}

@Test func configStoreGatewayRoundTrip() throws {
    // A workspace gateway + managerGateway survive a save/load through disk (CROW-402).
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    var config = AppConfig(
        workspaces: [
            WorkspaceInfo(
                name: "Corveil",
                gateway: WorkspaceGateway(
                    baseURL: "https://corveil.io",
                    customHeaders: ["x-citadel-api-key": "op://Spotlight Prod/Citadel/api_key"]
                )
            ),
            WorkspaceInfo(name: "Personal"),  // no gateway → vanilla Anthropic
        ]
    )
    config.managerGateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-citadel-api-key": "Bearer sk-citadel-456"]
    )

    try ConfigStore.saveConfig(config, to: claudeDir)
    let configURL = claudeDir.appendingPathComponent("config.json")
    let loaded = ConfigStore.loadConfig(from: configURL)

    #expect(loaded?.workspaces[0].gateway?.baseURL == "https://corveil.io")
    #expect(loaded?.workspaces[0].gateway?.customHeaders["x-citadel-api-key"] == "op://Spotlight Prod/Citadel/api_key")
    #expect(loaded?.workspaces[1].gateway == nil)
    #expect(loaded?.managerGateway?.customHeaders["x-citadel-api-key"] == "Bearer sk-citadel-456")
}

@Test func configStoreWebAuthRoundTrip() throws {
    // The web-password hash survives a save/load, and its presence is what marks
    // "a password is set" — the CLI's `web-password status` reads exactly this
    // (CROW-815). Clearing it removes the block rather than blanking the fields.
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let configURL = claudeDir.appendingPathComponent("config.json")

    var config = AppConfig()
    config.webAuth = WebAuthConfig(hashB64: "aGFzaA==", saltB64: "c2FsdA==", iterations: 210_000)
    try ConfigStore.saveConfig(config, to: claudeDir)

    let loaded = ConfigStore.loadConfig(from: configURL)
    #expect(loaded?.webAuth?.hashB64 == "aGFzaA==")
    #expect(loaded?.webAuth?.saltB64 == "c2FsdA==")
    #expect(loaded?.webAuth?.iterations == 210_000)

    config.webAuth = nil
    try ConfigStore.saveConfig(config, to: claudeDir)
    #expect(ConfigStore.loadConfig(from: configURL)?.webAuth == nil)
}

@Test func configStoreLoadReturnsNilOnMalformedGateway() throws {
    // A half-filled gateway (baseURL but no headers) is rejected at decode time;
    // loadConfig logs and returns nil rather than dropping just the bad field.
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let configURL = tmpDir.appendingPathComponent("config.json")
    try #"{"managerGateway": {"baseURL": "https://corveil.io", "customHeaders": {}}}"#
        .write(to: configURL, atomically: true, encoding: .utf8)

    #expect(ConfigStore.loadConfig(from: configURL) == nil)
}

// MARK: - Config path (CROW-813 review)

/// `configURL` / `configExists` are what the daemon's fail-closed write guard
/// asks before refusing to overwrite a malformed config. They have to name the
/// same file `loadConfig`/`saveConfig` use, or the guard silently stops guarding.
@Test func configURLMatchesWhereSaveConfigWrites() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    #expect(ConfigStore.configExists(devRoot: tmpDir.path) == false)

    try ConfigStore.saveConfig(AppConfig(), devRoot: tmpDir.path)

    let url = ConfigStore.configURL(devRoot: tmpDir.path)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(ConfigStore.configExists(devRoot: tmpDir.path))
    #expect(ConfigStore.loadConfig(from: url) != nil)
}

/// The distinction the guard rests on: `loadConfig` returns nil for a malformed
/// file just as it does for a missing one, but `configExists` still says yes.
@Test func configExistsIsTrueForAnUndecodableConfig() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    try "{ not json".write(
        to: claudeDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

    #expect(ConfigStore.loadConfig(devRoot: tmpDir.path) == nil)
    #expect(ConfigStore.configExists(devRoot: tmpDir.path))
}

// MARK: - Notification settings (CROW-813)

/// What `crow notifications set` does to the file: change some globals and one
/// event, leave every other event alone. `eventSettings` is keyed by a
/// non-`CodingKeyRepresentable` enum, so it serializes as a flat alternating
/// array — this pins that it survives a real save/load rather than only an
/// in-memory encode/decode.
@Test func configStoreNotificationsMutationRoundTrips() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    var config = AppConfig()
    config.notifications.globalMute = true
    config.notifications.systemNotificationsEnabled = false
    // Mirrors the handler's mutation: read through config(for:), write back.
    var event = config.notifications.config(for: .checksFailing)
    event.soundEnabled = false
    event.soundName = "Hero"
    config.notifications.eventSettings[.checksFailing] = event

    try ConfigStore.saveConfig(config, to: claudeDir)
    let loaded = ConfigStore.loadConfig(from: claudeDir.appendingPathComponent("config.json"))

    #expect(loaded?.notifications.globalMute == true)
    #expect(loaded?.notifications.soundEnabled == true)
    #expect(loaded?.notifications.systemNotificationsEnabled == false)
    let reloaded = try #require(loaded?.notifications.config(for: .checksFailing))
    #expect(reloaded.soundEnabled == false)
    #expect(reloaded.soundName == "Hero")
    #expect(reloaded.enabled == true)
    // Untouched events keep their defaults.
    #expect(loaded?.notifications.config(for: .taskComplete).soundName
        == NotificationEvent.taskComplete.defaultSound)
}

/// A per-event write against a config that omits the event — the common case,
/// since most config.json files predate the automation events. The handler
/// reads through `config(for:)` precisely so this isn't a silent no-op.
@Test func configStoreNotificationsWriteToEventAbsentFromFile() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let claudeDir = tmpDir.appendingPathComponent(".claude", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    var config = AppConfig()
    config.notifications.eventSettings = [:]
    var event = config.notifications.config(for: .autoRebaseConflicts)
    event.enabled = false
    config.notifications.eventSettings[.autoRebaseConflicts] = event

    try ConfigStore.saveConfig(config, to: claudeDir)
    let loaded = ConfigStore.loadConfig(from: claudeDir.appendingPathComponent("config.json"))

    #expect(loaded?.notifications.eventSettings.count == 1)
    #expect(loaded?.notifications.config(for: .autoRebaseConflicts).enabled == false)
    #expect(loaded?.notifications.config(for: .autoRebaseConflicts).soundName
        == NotificationEvent.autoRebaseConflicts.defaultSound)
    // Events still absent from the file resolve to their defaults on read.
    #expect(loaded?.notifications.config(for: .taskComplete).enabled == true)
}

/// A hand-edited `notifications` block naming only the field being changed must
/// not take the whole config down. Before CROW-813 this returned nil, silently
/// resetting every workspace, job, and credential to defaults on the next read.
@Test func configStoreLoadsPartialNotificationsBlock() throws {
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let configURL = tmpDir.appendingPathComponent("config.json")
    try #"{"remoteControlEnabled": true, "notifications": {"globalMute": true}}"#
        .write(to: configURL, atomically: true, encoding: .utf8)

    let loaded = try #require(ConfigStore.loadConfig(from: configURL))
    #expect(loaded.notifications.globalMute == true)
    #expect(loaded.notifications.soundEnabled == true)
    #expect(loaded.remoteControlEnabled == true)
}
