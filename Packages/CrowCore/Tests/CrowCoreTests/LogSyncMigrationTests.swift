import Foundation
import Testing
import CrowCore

@Suite struct LogSyncMigrationTests {
    /// Raw config JSON with a legacy `logSync` block, plus one workspace.
    private func rawConfig(logSyncJSON: String, workspaceName: String = "Corveil") -> Data {
        Data(#"""
        {"workspaces": [{"id": "\#(UUID().uuidString)", "name": "\#(workspaceName)",
          "provider": "github", "cli": "gh"}],
         "logSync": \#(logSyncJSON)}
        """#.utf8)
    }

    private func decoded(_ raw: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: raw)
    }

    @Test func migratesEnabledWorkspacesWhenMasterSwitchWasOn() throws {
        let raw = rawConfig(logSyncJSON: #"""
        {"enabled": true, "baseURL": "https://api", "apiKeyRef": "op://v/k",
         "enabledWorkspaces": ["corveil"]}
        """#)
        let config = try decoded(raw)
        #expect(config.workspaces[0].uploadSessionLogs == false) // legacy list, not the flag

        let migrated = try #require(LogSyncMigration.migrate(config: config, rawJSON: raw))
        #expect(migrated.workspaces[0].uploadSessionLogs == true) // folded in (case-insensitive)
    }

    @Test func doesNotEnableWhenMasterSwitchWasOff() throws {
        // A workspace listed but with `enabled: false` uploaded nothing before, so
        // the migration must not silently turn it on.
        let raw = rawConfig(logSyncJSON: #"""
        {"enabled": false, "enabledWorkspaces": ["Corveil"]}
        """#)
        let config = try decoded(raw)
        let migrated = try #require(LogSyncMigration.migrate(config: config, rawJSON: raw))
        #expect(migrated.workspaces[0].uploadSessionLogs == false)
    }

    @Test func firesOnAnyRemovedKeyEvenWithoutList() throws {
        // A block carrying only a removed key (no `enabledWorkspaces`) still fires,
        // so the re-encode drops the dead key — but changes no opt-in.
        let raw = rawConfig(logSyncJSON: #"{"baseURL": "https://api"}"#)
        let config = try decoded(raw)
        let migrated = try #require(LogSyncMigration.migrate(config: config, rawJSON: raw))
        #expect(migrated.workspaces[0].uploadSessionLogs == false)
    }

    @Test func slimBlockIsANoOp() throws {
        // A config already on the slim shape has no removed key → nothing to do.
        let raw = rawConfig(logSyncJSON: #"{"retentionDays": 14, "quietPeriodMinutes": 30, "maxUploadBytes": 8000000}"#)
        let config = try decoded(raw)
        #expect(LogSyncMigration.migrate(config: config, rawJSON: raw) == nil)
    }

    @Test func absentBlockIsANoOp() throws {
        let raw = Data(#"""
        {"workspaces": [{"id": "\#(UUID().uuidString)", "name": "Corveil",
          "provider": "github", "cli": "gh"}]}
        """#.utf8)
        let config = try decoded(raw)
        #expect(LogSyncMigration.migrate(config: config, rawJSON: raw) == nil)
    }

    @Test func isIdempotentAcrossReEncode() throws {
        // Migrate → encode (slim) → decode → migrate again is a no-op: the removed
        // keys are gone after the first save, so the second pass returns nil.
        let raw = rawConfig(logSyncJSON: #"""
        {"enabled": true, "enabledWorkspaces": ["Corveil"], "retentionDays": 14}
        """#)
        let config = try decoded(raw)
        let migrated = try #require(LogSyncMigration.migrate(config: config, rawJSON: raw))
        #expect(migrated.workspaces[0].uploadSessionLogs == true)
        #expect(migrated.logSync?.retentionDays == 14) // knob preserved

        let reencoded = try JSONEncoder().encode(migrated)
        let reloaded = try JSONDecoder().decode(AppConfig.self, from: reencoded)
        #expect(LogSyncMigration.migrate(config: reloaded, rawJSON: reencoded) == nil)
    }
}
