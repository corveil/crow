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

    @Test @MainActor func uiSetPatchesSwitcherFields() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("ui-set", [
            "switcher_enabled": .bool(false),
            "switcher_binding": .string("ctrl+`"),
            "switcher_capture_in_terminal": .bool(false),
            "switcher_order": .string("sidebar"),
            "switcher_preview": .bool(false),
            "switcher_include_managers": .bool(true),
            "switcher_include_completed": .bool(true),
        ], devRoot: devRoot)

        #expect(resp.result?["ui"] == .object([
            "sidebar": .object(["hide_session_details": .bool(false)]),
            "switcher": .object([
                "enabled": .bool(false),
                "binding": .string("ctrl+`"),
                "capture_in_terminal": .bool(false),
                "order": .string("sidebar"),
                "preview": .bool(false),
                "include": .object([
                    "managers": .bool(true),
                    "jobs": .bool(false),
                    "reviews": .bool(true),
                    "active": .bool(true),
                    "paused": .bool(true),
                    "in_review": .bool(true),
                    "completed": .bool(true),
                    "archived": .bool(false),
                ]),
            ]),
        ]))

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.switcher.enabled == false)
        #expect(onDisk.switcher.binding == "ctrl+`")
        #expect(onDisk.switcher.captureInTerminal == false)
        #expect(onDisk.switcher.order == .sidebar)
        #expect(onDisk.switcher.preview == false)
        #expect(onDisk.switcher.include.managers == true)
        #expect(onDisk.switcher.include.completed == true)
        // Unpatched include keys keep their defaults.
        #expect(onDisk.switcher.include.reviews == true)
        #expect(onDisk.switcher.include.jobs == false)
    }

    /// CROW-1002: the chord agents cycle permission modes with is refused at the
    /// setter rather than stored and rewritten on the next decode — a silent
    /// revert would leave the user with nothing to explain why it didn't stick.
    @Test @MainActor func uiSetRejectsReservedSwitcherBinding() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        for attempt in ["shift+tab", "Shift+Tab", " shift+tab "] {
            let resp = await call("ui-set", [
                "switcher_binding": .string(attempt),
                "switcher_preview": .bool(false),
            ], devRoot: devRoot)

            #expect(resp.result == nil)
            #expect(resp.error?.message.contains("reserved") == true)
            // The whole patch is refused, not just the offending field — a
            // partial write would leave the config in a state nobody asked for.
            #expect(ConfigStore.loadConfig(devRoot: devRoot)?.switcher.preview != false)
        }
    }

    /// Rejection is scoped to that one chord: the CROW-980 default still sets.
    @Test @MainActor func uiSetAcceptsEscTabSwitcherBinding() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("ui-set", ["switcher_binding": .string("esc+tab")], devRoot: devRoot)

        #expect(resp.error == nil)
        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.switcher.binding == "esc+tab")
    }

    // MARK: - terminal (CROW-1085)

    @Test @MainActor func terminalSetPatchesWheelKnobs() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("terminal-set", [
            "wheel_scroll_lines": .int(5),
            "agent_wheel_notches": .int(2),
        ], devRoot: devRoot)

        #expect(resp.result?["terminal"] == .object([
            "wheel_scroll_lines": .int(5),
            "agent_wheel_notches": .int(2),
        ]))
        #expect(resp.result?["restart_required"] == .bool(false))

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.terminal.wheelScrollLines == 5)
        #expect(onDisk.terminal.agentWheelNotches == 2)
    }

    /// A one-field patch leaves the other knob at its stored value — the PATCH
    /// contract, same as the switcher fields.
    @Test @MainActor func terminalSetLeavesUnpatchedKnobAlone() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        var seed = AppConfig()
        seed.terminal = TerminalSettings(wheelScrollLines: 8, agentWheelNotches: 3)
        try ConfigStore.saveConfig(seed, devRoot: devRoot)

        _ = await call("terminal-set", ["wheel_scroll_lines": .int(2)], devRoot: devRoot)

        let onDisk = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(onDisk.terminal.wheelScrollLines == 2)
        #expect(onDisk.terminal.agentWheelNotches == 3)
    }

    @Test @MainActor func terminalGetEchoesDefaults() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let resp = await call("terminal-get", devRoot: devRoot)
        #expect(resp.result?["terminal"] == .object([
            "wheel_scroll_lines": .int(3),
            "agent_wheel_notches": .int(1),
        ]))
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

        let terminal = await call("terminal-set", ["wheel_scroll_lines": .int(5)], devRoot: devRoot)
        #expect(terminal.result?["restart_required"] == .bool(false))
    }

    // MARK: - Rejections

    @Test @MainActor func setsRejectEmptyParams() async {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // A no-op write would still rewrite config.json and fire a spurious
        // "Config reloaded" notification in every open browser.
        for method in ["telemetry-set", "cleanup-set", "ui-set", "terminal-set"] {
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
            ("terminal-set", ["wheel_scroll_lines": .int(0)]),
            ("terminal-set", ["agent_wheel_notches": .int(0)]),
            ("terminal-set", ["wheel_scroll_lines": .int(-3)]),
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
            ("terminal-set", ["wheel_scroll_lines": .string("5")]),
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
