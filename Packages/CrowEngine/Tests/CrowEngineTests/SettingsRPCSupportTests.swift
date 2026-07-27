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
    @Test func settingsResponsesNeverContainCredentialKeys() throws {
        let responses = [
            SettingsRPC.telemetryJSON(TelemetryConfig()),
            SettingsRPC.cleanupJSON(CleanupConfig()),
            SettingsRPC.uiJSON(SidebarSettings()),
        ]
        for json in responses {
            let text = String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
            for secret in ["tokenRef", "hashB64", "saltB64", "customHeaders",
                           "jiraCredential", "webAuth", "managerGateway", "binaries"] {
                #expect(!text.contains(secret), "\(secret) leaked into \(text)")
            }
        }
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
