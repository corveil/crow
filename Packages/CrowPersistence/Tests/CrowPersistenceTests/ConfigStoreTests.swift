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
