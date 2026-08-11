import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import CrowEngine
@testable import CrowDaemon

/// End-to-end coverage of the `telemetry-*` / `cleanup-*` / `ui-*` handlers
/// behind `crow telemetry` / `crow cleanup` / `crow ui` (CROW-814): the real
/// router, against a real `config.json` in a temp dev root.
///
/// The unit tests in `SettingsRPCSupportTests` pin the pure decode/encode; these
/// pin the parts only the handler can get wrong — that a patch touches exactly
/// the fields it was given, that it persists, and that unrelated config survives.
@Suite struct SettingsHandlerTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-settings-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor
    private func router(devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    @MainActor
    private func call(
        _ method: String, _ params: [String: JSONValue] = [:], devRoot: String
    ) async -> JSONRPCResponse {
        await router(devRoot: devRoot)
            .handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    // MARK: - Reads

    @Test @MainActor func getsReturnDefaultsWhenNoConfigExists() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let telemetry = await call("telemetry-get", devRoot: devRoot)
        #expect(telemetry.result?["telemetry"] == .object([
            "enabled": .bool(false), "port": .int(4318), "retention_days": .int(180),
        ]))

        let cleanup = await call("cleanup-get", devRoot: devRoot)
        #expect(cleanup.result?["cleanup"] == .object([
            "enabled": .bool(false), "retention_hours": .int(24),
        ]))

        let ui = await call("ui-get", devRoot: devRoot)
        #expect(ui.result?["ui"] == .object([
            "sidebar": .object(["hide_session_details": .bool(false)]),
            "switcher": SettingsRPC.switcherJSON(SwitcherSettings()),
        ]))
    }

    // MARK: - Patch semantics

    @Test @MainActor func telemetrySetPatchesOnlyProvidedFields() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.telemetry = TelemetryConfig(enabled: true, port: 4318, retentionDays: 180)
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("telemetry-set", ["retention_days": .int(30)], devRoot: devRoot)

        // Only retention moved; enabled/port kept their stored values.
        #expect(resp.result?["telemetry"] == .object([
            "enabled": .bool(true), "port": .int(4318), "retention_days": .int(30),
        ]))
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.telemetry.enabled == true)
        #expect(onDisk.telemetry.port == 4318)
        #expect(onDisk.telemetry.retentionDays == 30)
    }

    /// `--enabled false` must be a real write, not read as "absent".
    @Test @MainActor func settingFalseIsAWriteNotANoOp() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.cleanup = CleanupConfig(enabled: true, retentionHours: 72)
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let resp = await call("cleanup-set", ["enabled": .bool(false)], devRoot: devRoot)

        #expect(resp.result?["cleanup"] == .object([
            "enabled": .bool(false), "retention_hours": .int(72),
        ]))
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.cleanup.enabled == false)
    }

    /// The whole reason these are granular RPCs rather than a `set-config` blob
    /// round-trip: a settings write must not disturb anything else in the file.
    @Test @MainActor func writesPreserveUnrelatedConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.workspaces = [WorkspaceInfo(
            name: "Corveil", provider: "github", cli: "gh", alwaysInclude: ["corveil/crow"])]
        seed.jobs = [JobConfig(
            name: "nightly", workspace: "Corveil", repo: "corveil/crow",
            prompts: ["triage"], schedule: .interval(seconds: 3600))]
        seed.jiraCredential = JiraCredential(
            username: "a@b.c", tokenRef: "op://vault/jira/token")
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        _ = await call("ui-set", ["hide_session_details": .bool(true)], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.sidebar.hideSessionDetails == true)
        #expect(onDisk.workspaces.map(\.name) == ["Corveil"])
        #expect(onDisk.jobs.map(\.name) == ["nightly"])
        #expect(onDisk.jiraCredential?.tokenRef == "op://vault/jira/token")
    }

    // MARK: - restart_required

    @Test @MainActor func telemetryReportsRestartOnlyForEnabledOrPort() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.telemetry = TelemetryConfig(enabled: true, port: 4318, retentionDays: 180)
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        let port = await call("telemetry-set", ["port": .int(4319)], devRoot: devRoot)
        #expect(port.result?["restart_required"] == .bool(true))

        let retention = await call("telemetry-set", ["retention_days": .int(90)], devRoot: devRoot)
        #expect(retention.result?["restart_required"] == .bool(false))

        // Re-setting the same port is not a change, so it needs no restart.
        let same = await call("telemetry-set", ["port": .int(4319)], devRoot: devRoot)
        #expect(same.result?["restart_required"] == .bool(false))
    }

    @Test @MainActor func liveSettingsNeverReportRestart() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let cleanup = await call("cleanup-set", ["retention_hours": .int(72)], devRoot: devRoot)
        #expect(cleanup.result?["restart_required"] == .bool(false))

        let ui = await call("ui-set", ["hide_session_details": .bool(true)], devRoot: devRoot)
        #expect(ui.result?["restart_required"] == .bool(false))
    }

    // MARK: - Rejections

    @Test @MainActor func setsRejectEmptyParams() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // A no-op write would still rewrite config.json and fire a spurious
        // "Config reloaded" notification in every open browser.
        for method in ["telemetry-set", "cleanup-set", "ui-set"] {
            let resp = await call(method, devRoot: devRoot)
            #expect(resp.error?.code == RPCErrorCode.invalidParams, "\(method) must reject empty params")
        }
        #expect(!FileManager.default.fileExists(
            atPath: (devRoot as NSString).appendingPathComponent(".claude/config.json")))
    }

    @Test @MainActor func setsRejectOutOfRangeValues() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let cases: [(String, [String: JSONValue])] = [
            ("telemetry-set", ["port": .int(80)]),
            ("telemetry-set", ["port": .int(70000)]),
            ("telemetry-set", ["retention_days": .int(-1)]),
            ("cleanup-set", ["retention_hours": .int(0)]),
            ("cleanup-set", ["retention_hours": .int(-24)]),
        ]
        for (method, params) in cases {
            let resp = await call(method, params, devRoot: devRoot)
            #expect(resp.error?.code == RPCErrorCode.invalidParams, "\(method) \(params)")
        }
    }

    /// A wrong-typed value must fail loudly rather than being read as "absent"
    /// and reported as a successful write that changed nothing.
    @Test @MainActor func setsRejectWrongTypesRatherThanIgnoringThem() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let cases: [(String, [String: JSONValue])] = [
            ("telemetry-set", ["enabled": .string("true")]),
            ("cleanup-set", ["enabled": .int(1)]),
            ("ui-set", ["hide_session_details": .string("yes")]),
            ("telemetry-set", ["port": .string("4318")]),
        ]
        for (method, params) in cases {
            let resp = await call(method, params, devRoot: devRoot)
            #expect(resp.error?.code == RPCErrorCode.invalidParams, "\(method) \(params)")
        }
    }

    /// `ConfigStore.loadConfig` returns nil for both "missing" and "malformed".
    /// Treating the latter as "missing" and falling back to `AppConfig()` would
    /// silently reset every workspace, job and credential on the next write.
    @Test @MainActor func writeRefusesToOverwriteAnUndecodableConfig() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            atPath: claudeDir, withIntermediateDirectories: true)
        let configPath = (claudeDir as NSString).appendingPathComponent("config.json")
        let corrupt = #"{"workspaces": "not-an-array"}"#
        try corrupt.write(toFile: configPath, atomically: true, encoding: .utf8)

        let resp = await call("ui-set", ["hide_session_details": .bool(true)], devRoot: devRoot)

        #expect(resp.error?.code == RPCErrorCode.applicationError)
        // The bad file is left exactly as it was, not replaced with defaults.
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == corrupt)
    }
}
