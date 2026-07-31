import Foundation
import Testing
import CrowCore
import CrowIPC
@testable import CrowEngine

/// Param decoding and response encoding for the `telemetry-*` / `cleanup-*` /
/// `ui-*` RPC handlers (CROW-814).
@Suite("Settings RPC support")
struct SettingsRPCSupportTests {

    // MARK: - patchBool

    /// The PATCH contract: only a genuinely provided value changes anything.
    @Test func patchBoolReturnsNilForAbsentAndNull() throws {
        #expect(try SettingsRPC.patchBool([:], "enabled") == nil)
        #expect(try SettingsRPC.patchBool(["enabled": .null], "enabled") == nil)
    }

    /// `false` must be distinguishable from "not provided" — otherwise
    /// `--enabled false` would silently do nothing.
    @Test func patchBoolAcceptsBothLiterals() throws {
        #expect(try SettingsRPC.patchBool(["enabled": .bool(true)], "enabled") == true)
        #expect(try SettingsRPC.patchBool(["enabled": .bool(false)], "enabled") == false)
    }

    /// Regression guard against `job-edit`'s `params[key]?.boolValue` idiom, which
    /// treats a wrong-typed value as absent and reports success for a write it
    /// silently dropped.
    @Test func patchBoolRejectsWrongTypes() {
        let bad: [JSONValue] = [.string("true"), .int(1), .double(1.0), .object([:]), .array([])]
        for value in bad {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try SettingsRPC.patchBool(["enabled": value], "enabled")
            }
        }
    }

    // MARK: - patchPort

    @Test func patchPortAcceptsInRangeValues() throws {
        #expect(try SettingsRPC.patchPort(["port": .int(1024)]) == 1024)
        #expect(try SettingsRPC.patchPort(["port": .int(4318)]) == 4318)
        #expect(try SettingsRPC.patchPort(["port": .int(65535)]) == 65535)
        #expect(try SettingsRPC.patchPort([:]) == nil)
    }

    @Test func patchPortRejectsOutOfRangeAndNonInteger() {
        // 65536 and 70000 matter beyond ergonomics: `TelemetryConfig.port` is a
        // `UInt16`, so persisting one would make the whole config.json undecodable
        // on the next load, and every later write would then be refused.
        let bad: [JSONValue] = [
            .int(0), .int(80), .int(1023), .int(65536), .int(70000), .int(-1),
            .string("4318"), .bool(true),
        ]
        for value in bad {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try SettingsRPC.patchPort(["port": value])
            }
        }
    }

    // MARK: - retention

    /// 0 is legal for telemetry — it's the pruner's documented "keep forever".
    @Test func patchRetentionDaysAcceptsZeroAsForever() throws {
        #expect(try SettingsRPC.patchRetentionDays(["retention_days": .int(0)]) == 0)
        #expect(try SettingsRPC.patchRetentionDays(["retention_days": .int(365)]) == 365)
    }

    @Test func patchRetentionDaysRejectsNegative() {
        #expect(throws: RPCError.self) {
            _ = try SettingsRPC.patchRetentionDays(["retention_days": .int(-1)])
        }
    }

    /// Deliberate asymmetry with telemetry: cleanup has no "forever". 0 deletes a
    /// session the moment it completes; a negative value moves the cutoff into the
    /// future and sweeps every completed/archived session, worktree and branch
    /// included.
    @Test func patchRetentionHoursRejectsZeroAndNegative() throws {
        #expect(try SettingsRPC.patchRetentionHours(["retention_hours": .int(1)]) == 1)
        #expect(try SettingsRPC.patchRetentionHours(["retention_hours": .int(720)]) == 720)
        for value in [0, -1, -24] {
            #expect(throws: RPCError.self, "expected \(value) to be rejected") {
                _ = try SettingsRPC.patchRetentionHours(["retention_hours": .int(value)])
            }
        }
    }

    // MARK: - Response encoding

    @Test func telemetryJSONUsesSnakeCaseScalars() throws {
        let json = SettingsRPC.telemetryJSON(
            TelemetryConfig(enabled: true, port: 4319, retentionDays: 30))
        #expect(json == .object([
            "enabled": .bool(true),
            "port": .int(4319),
            "retention_days": .int(30),
        ]))
    }

    @Test func cleanupJSONUsesSnakeCaseScalars() throws {
        let json = SettingsRPC.cleanupJSON(CleanupConfig(enabled: true, retentionHours: 72))
        #expect(json == .object([
            "enabled": .bool(true),
            "retention_hours": .int(72),
        ]))
    }

    /// Locks the nesting by config block, so flattening it later is a conscious
    /// break rather than an accident — `ui` grows to hold more blocks.
    @Test func uiJSONNestsUnderSidebar() throws {
        let json = SettingsRPC.uiJSON(SidebarSettings(hideSessionDetails: true))
        #expect(json == .object([
            "sidebar": .object(["hide_session_details": .bool(true)]),
        ]))
    }

    /// Unlike `get-config`, these responses carry no credential shell at all, so
    /// they need no `SettingsSecrets.strippedForTransport` pass. Pin that, because
    /// a future "just reuse the config encoder" refactor would quietly break it.
    ///
    /// `automationJSON` is the one that could plausibly regress: it takes a whole
    /// `AppConfig`, so it is built from a config that *does* carry credentials.
    @Test func settingsResponsesNeverContainCredentialKeys() throws {
        var loaded = AppConfig()
        loaded.jiraCredential = JiraCredential(
            username: "a@b.c", tokenRef: "op://vault/jira/SECRET-TOKEN")
        loaded.managerGateway = WorkspaceGateway(
            baseURL: "https://gw.example", customHeaders: ["X-Api-Key": "sk-live-SECRET-KEY"])
        loaded.defaults.binaries = ["claude-code": "/opt/SECRET-PATH/claude"]

        let responses = [
            SettingsRPC.telemetryJSON(TelemetryConfig()),
            SettingsRPC.cleanupJSON(CleanupConfig()),
            SettingsRPC.uiJSON(SidebarSettings()),
            SettingsRPC.automationJSON(AppConfig()),
            SettingsRPC.automationJSON(loaded),
        ]
        for json in responses {
            let text = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
            for secret in ["tokenRef", "hashB64", "saltB64", "customHeaders",
                           "jiraCredential", "webAuth", "managerGateway", "binaries",
                           "SECRET-TOKEN", "SECRET-KEY", "SECRET-PATH"] {
                #expect(!text.contains(secret), "\(secret) leaked into \(text)")
            }
        }
    }

    // MARK: - Automation (CROW-812)

    @Test func automationJSONMirrorsConfigDefaults() throws {
        let json = try #require(SettingsRPC.automationJSON(AppConfig()).objectValue)

        // The six that ship on. A caller scripting against these needs the
        // defaults to be exactly what `AppConfig()` says, not what "automation
        // off by default" would suggest.
        #expect(json["manager_auto_permission_mode"] == .bool(true))
        #expect(json["review_auto_permission_mode"] == .bool(true))
        #expect(json["jobs_auto_permission_mode"] == .bool(true))
        #expect(json["attribution_trailers"] == .bool(true))
        #expect(json["remote_control_enabled"] == .bool(false))
        #expect(json["coder_view_auto_permission_mode"] == .bool(false))
        #expect(json["auto_create_watcher_enabled"] == .bool(false))
        #expect(json["auto_merge_watcher_enabled"] == .bool(false))
        #expect(json["config_readable"] == .bool(true))

        #expect(json["auto_respond"] == .object([
            "respond_to_changes_requested": .bool(true),
            "respond_to_failed_checks": .bool(false),
            "auto_rebase_and_resolve_conflicts": .bool(false),
            "auto_re_request_review": .bool(true),
        ]))
        #expect(json["defaults"] == .object([
            "exclude_review_repos": .array([]),
            "ignore_review_labels": .array([]),
            "exclude_ticket_repos": .array([]),
            "effective_exclude_review_repos": .array([]),
        ]))
    }

    /// Locks the nesting by config block for the same reason as `uiJSON`: the
    /// board-filter lists live under `AppConfig.defaults`, not at top level, so
    /// flattening them later is a conscious break rather than an accident.
    @Test func automationJSONNestsListsUnderDefaults() throws {
        var config = AppConfig()
        config.defaults.excludeReviewRepos = ["corveil/*"]
        config.defaults.ignoreReviewLabels = ["wip", "do not merge"]
        config.defaults.excludeTicketRepos = ["owner/archive"]

        let defaults = try #require(
            SettingsRPC.automationJSON(config).objectValue?["defaults"]?.objectValue)
        #expect(defaults["exclude_review_repos"] == .array([.string("corveil/*")]))
        #expect(defaults["ignore_review_labels"]
            == .array([.string("wip"), .string("do not merge")]))
        #expect(defaults["exclude_ticket_repos"] == .array([.string("owner/archive")]))
    }

    /// The derived field earns its place: the CLI can't see per-workspace
    /// excludes any other way, so without it a caller can't explain why a repo is
    /// still hidden from the review board.
    @Test func automationJSONReportsEffectiveExcludeReviewRepos() throws {
        var config = AppConfig()
        config.defaults.excludeReviewRepos = ["corveil/*"]
        config.workspaces = [
            WorkspaceInfo(name: "Acme", excludeReviewRepos: ["acme/legacy"]),
        ]

        let defaults = try #require(
            SettingsRPC.automationJSON(config).objectValue?["defaults"]?.objectValue)
        #expect(defaults["exclude_review_repos"] == .array([.string("corveil/*")]))
        #expect(defaults["effective_exclude_review_repos"]
            == .array([.string("corveil/*"), .string("acme/legacy")]))
    }

    @Test func automationJSONReportsConfigReadable() throws {
        let json = SettingsRPC.automationJSON(AppConfig(), configReadable: false).objectValue
        #expect(json?["config_readable"] == .bool(false))
    }

    // MARK: - restart_required

    @Test func telemetryRestartRequiredOnEnabledOrPortChange() {
        let base = TelemetryConfig(enabled: false, port: 4318, retentionDays: 180)

        #expect(SettingsRPC.telemetryRestartRequired(
            old: base, new: TelemetryConfig(enabled: true, port: 4318, retentionDays: 180)))
        #expect(SettingsRPC.telemetryRestartRequired(
            old: base, new: TelemetryConfig(enabled: false, port: 4319, retentionDays: 180)))

        // retentionDays alone only shifts the next boot prune's window — reporting
        // a restart for it would train users to ignore the flag.
        #expect(!SettingsRPC.telemetryRestartRequired(
            old: base, new: TelemetryConfig(enabled: false, port: 4318, retentionDays: 30)))
        #expect(!SettingsRPC.telemetryRestartRequired(old: base, new: base))
    }
}
