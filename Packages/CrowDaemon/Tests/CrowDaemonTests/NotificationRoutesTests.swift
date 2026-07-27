import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// End-to-end for the `notifications-*` routes (CROW-813): request in through
/// the real router, `config.json` out on disk. Covers what a unit test on
/// `NotificationRPC` can't — the read-modify-write under the config lock, the
/// param-combination rejections, and the fail-closed guard on an undecodable
/// config.
@Suite struct NotificationRoutesTests {
    private func tempDevRoot() -> String {
        let dir = NSTemporaryDirectory() + "crow-notif-" + UUID().uuidString
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func router(devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(),
            store: JSONStore.temporary(),
            git: GitManager(),
            devRoot: devRoot,
            cockpit: nil)
    }

    private func notifications(_ result: [String: JSONValue]?) throws -> [String: JSONValue] {
        try #require(result?["notifications"]?.objectValue)
    }

    private func events(_ result: [String: JSONValue]?) throws -> [String: JSONValue] {
        try #require(try notifications(result)["events"]?.objectValue)
    }

    // MARK: - get

    @Test func getReturnsDefaultsWhenNoConfigExists() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await router(devRoot: devRoot)
            .handle(request: JSONRPCRequest(id: 1, method: "notifications-get"))

        #expect(resp.error == nil)
        let object = try notifications(resp.result)
        #expect(object["global_mute"]?.boolValue == false)
        // No config yet is not the same as an unreadable one — the defaults
        // shown really are what applies.
        #expect(object["config_readable"]?.boolValue == true)
        #expect(try events(resp.result).count == NotificationEvent.allCases.count)
    }

    @Test func getFiltersToOneEventButKeepsGlobals() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var config = AppConfig()
        config.notifications.globalMute = true
        try ConfigStore.saveConfig(config, devRoot: devRoot)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-get", params: ["event": .string("checksFailing")]))

        #expect(resp.error == nil)
        #expect(try events(resp.result).count == 1)
        #expect(try events(resp.result)["checksFailing"] != nil)
        #expect(try notifications(resp.result)["global_mute"]?.boolValue == true)
    }

    @Test func getRejectsUnknownEvent() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-get", params: ["event": .string("nope")]))

        #expect(resp.error != nil)
    }

    /// An undecodable config is reported as such rather than passed off as the
    /// user's real settings.
    @Test func getFlagsAnUnreadableConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = URL(fileURLWithPath: devRoot).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try "{ not json".write(
            to: claudeDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let resp = await router(devRoot: devRoot)
            .handle(request: JSONRPCRequest(id: 1, method: "notifications-get"))

        #expect(resp.error == nil)
        #expect(try notifications(resp.result)["config_readable"]?.boolValue == false)
    }

    // MARK: - set

    @Test func setPersistsGlobalTogglesToDisk() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: [
                "global_mute": .bool(true),
                "sound_enabled": .bool(false),
            ]))

        #expect(resp.error == nil)
        #expect(resp.result?["saved"]?.boolValue == true)
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(stored.notifications.globalMute == true)
        #expect(stored.notifications.soundEnabled == false)
        #expect(stored.notifications.systemNotificationsEnabled == true)
    }

    /// The mutation reads through `config(for:)`, so it lands even when the
    /// event is absent from the stored config — a subscript write would have
    /// been a silent no-op that still reported success.
    @Test func setWritesAnEventAbsentFromTheStoredConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var config = AppConfig()
        config.notifications.eventSettings = [:]
        try ConfigStore.saveConfig(config, devRoot: devRoot)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: [
                "event": .string("autoRebaseConflicts"),
                "event_enabled": .bool(false),
                "event_sound_name": .string("hero"),
            ]))

        #expect(resp.error == nil)
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        let event = try #require(stored.notifications.eventSettings[.autoRebaseConflicts])
        #expect(event.enabled == false)
        // Canonicalized from the lowercase input.
        #expect(event.soundName == "Hero")
        // Only the named event is materialized — everything else stays absent so
        // it keeps following the current defaults.
        #expect(stored.notifications.eventSettings.count == 1)
    }

    @Test func setLeavesUnnamedFieldsAlone() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var config = AppConfig()
        config.notifications.soundEnabled = false
        config.notifications.eventSettings[.taskComplete] = EventNotificationConfig(
            enabled: false, soundName: "Ping")
        try ConfigStore.saveConfig(config, devRoot: devRoot)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: [
                "event": .string("taskComplete"),
                "event_sound_name": .string("Tink"),
            ]))

        #expect(resp.error == nil)
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(stored.notifications.soundEnabled == false)          // untouched global
        #expect(stored.notifications.eventSettings[.taskComplete]?.enabled == false) // untouched field
        #expect(stored.notifications.eventSettings[.taskComplete]?.soundName == "Tink")
    }

    /// A globals-only write must not materialize event entries.
    @Test func setGlobalsDoesNotTouchEventSettings() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(AppConfig(), devRoot: devRoot)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: ["global_mute": .bool(true)]))

        #expect(resp.error == nil)
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.notifications.eventSettings.isEmpty == true)
    }

    /// The realistic shapes a first write lands on — a config with no
    /// `notifications` block at all, a hand-edited partial block, and no config
    /// file whatsoever. Each used to persist all ten events, freezing today's
    /// `defaultSound` table into the file and contradicting the sparse-write
    /// contract this handler documents (review of #813). The earlier version of
    /// `setGlobalsDoesNotTouchEventSettings` missed it by pre-seeding an
    /// explicitly-empty dictionary, which was never what a real config held.
    @Test(arguments: [
        #"{"remoteControlEnabled": true}"#,
        #"{"notifications": {"globalMute": false}}"#,
        #"{}"#,
    ])
    func setGlobalsAgainstARealisticConfigStaysSparse(configJSON: String) async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = URL(fileURLWithPath: devRoot).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try configJSON.write(
            to: claudeDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: ["global_mute": .bool(true)]))

        #expect(resp.error == nil)
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(stored.notifications.globalMute == true)
        #expect(stored.notifications.eventSettings.isEmpty)
    }

    /// Same contract with no config file at all — the write creates one, and it
    /// must still carry only what was asked for.
    @Test func setGlobalsWithNoConfigFileStaysSparse() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: ["global_mute": .bool(true)]))

        #expect(resp.error == nil)
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(stored.notifications.globalMute == true)
        #expect(stored.notifications.eventSettings.isEmpty)
    }

    /// A per-event write against a realistic config persists exactly one entry.
    @Test func setOneEventAgainstARealisticConfigWritesOnlyThatEvent() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = URL(fileURLWithPath: devRoot).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try #"{"remoteControlEnabled": true}"#.write(
            to: claudeDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: [
                "event": .string("checksFailing"), "event_enabled": .bool(false),
            ]))

        #expect(resp.error == nil)
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(stored.notifications.eventSettings.count == 1)
        #expect(stored.notifications.eventSettings[.checksFailing]?.enabled == false)
        // Written through `config(for:)`, so the entry carries the event's own
        // default sound rather than the bare `EventNotificationConfig` default.
        #expect(stored.notifications.eventSettings[.checksFailing]?.soundName
            == NotificationEvent.checksFailing.defaultSound)
    }

    @Test func setRejectsBadParamCombinations() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = await router(devRoot: devRoot)

        // Nothing to set.
        var resp = await router.handle(
            request: JSONRPCRequest(id: 1, method: "notifications-set", params: [:]))
        #expect(resp.error != nil)

        // event_* without event.
        resp = await router.handle(request: JSONRPCRequest(
            id: 2, method: "notifications-set", params: ["event_enabled": .bool(true)]))
        #expect(resp.error != nil)

        // event with nothing to change.
        resp = await router.handle(request: JSONRPCRequest(
            id: 3, method: "notifications-set", params: ["event": .string("taskComplete")]))
        #expect(resp.error != nil)

        // Unknown sound.
        resp = await router.handle(request: JSONRPCRequest(
            id: 4, method: "notifications-set", params: [
                "event": .string("taskComplete"), "event_sound_name": .string("Nope"),
            ]))
        #expect(resp.error != nil)

        // Nothing above should have created a config.
        #expect(ConfigStore.loadConfig(devRoot: devRoot) == nil)
    }

    // MARK: - fail-closed write guard

    /// Writing a setting against an undecodable `config.json` used to replace
    /// every workspace, job, and credential with defaults and report success,
    /// because `loadConfig`'s nil (file absent OR unparseable) fell through to
    /// `?? AppConfig()`. It must refuse instead, leaving the file untouched.
    @Test func setRefusesToOverwriteAnUndecodableConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = URL(fileURLWithPath: devRoot).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let configURL = claudeDir.appendingPathComponent("config.json")
        let corrupt = #"{"workspaces": [{"name": "Corveil"}], "#
        try corrupt.write(to: configURL, atomically: true, encoding: .utf8)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "notifications-set", params: ["global_mute": .bool(true)]))

        #expect(resp.error != nil)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == corrupt)
    }

    /// The same guard protects the `job-*` verbs, which share the helper.
    @Test func jobAddRefusesToOverwriteAnUndecodableConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = URL(fileURLWithPath: devRoot).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let configURL = claudeDir.appendingPathComponent("config.json")
        let corrupt = "{ not json"
        try corrupt.write(to: configURL, atomically: true, encoding: .utf8)

        let resp = await router(devRoot: devRoot).handle(request: JSONRPCRequest(
            id: 1, method: "job-add", params: [
                "name": .string("nightly"),
                "workspace": .string("Corveil"),
                "repo": .string("corveil/crow"),
                "prompts": .array([.string("do stuff")]),
                "schedule": .object(["type": .string("interval"), "seconds": .int(3600)]),
            ]))

        #expect(resp.error != nil)
        #expect(try String(contentsOf: configURL, encoding: .utf8) == corrupt)
    }
}
