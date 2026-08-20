import Foundation
import Testing
import CrowCore

@Suite struct LogSyncConfigTests {
    @Test func defaultsAreTheDefaults() {
        let c = LogSyncConfig()
        #expect(c.retentionDays == 30)
        #expect(c.quietPeriodMinutes == 30)
        #expect(c.maxUploadBytes == 8_000_000)
    }

    @Test func codableRoundTrip() throws {
        let c = LogSyncConfig(retentionDays: 14, quietPeriodMinutes: 10, maxUploadBytes: 1_000_000)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(LogSyncConfig.self, from: data)
        #expect(decoded == c)
    }

    @Test func tolerantDecodeOfPartialBlock() throws {
        // An older config.json with only some knobs still decodes to defaults.
        let json = #"{"retentionDays": 7}"#
        let decoded = try JSONDecoder().decode(LogSyncConfig.self, from: Data(json.utf8))
        #expect(decoded.retentionDays == 7)
        #expect(decoded.quietPeriodMinutes == 30) // defaulted
        #expect(decoded.maxUploadBytes == 8_000_000) // defaulted
    }

    @Test func decodeIgnoresRemovedKeysAndReEncodeDropsThem() throws {
        // A config written before CROW-1070 still carries the removed keys. They
        // must decode without error (ignored) and NOT survive a re-encode, so the
        // slim block replaces them on the next save.
        let json = #"""
        {"enabled": true, "baseURL": "https://x", "apiKeyRef": "op://v/k",
         "enabledWorkspaces": ["ws1"], "retentionDays": 14}
        """#
        let decoded = try JSONDecoder().decode(LogSyncConfig.self, from: Data(json.utf8))
        #expect(decoded.retentionDays == 14) // the one surviving knob
        let reencoded = try JSONEncoder().encode(decoded)
        let obj = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(obj?.keys.sorted() == ["maxUploadBytes", "quietPeriodMinutes", "retentionDays"])
        #expect(obj?["enabled"] == nil)
        #expect(obj?["baseURL"] == nil)
        #expect(obj?["apiKeyRef"] == nil)
        #expect(obj?["enabledWorkspaces"] == nil)
    }

    @Test func appConfigRoundTripsLogSyncAndDefaultsToNil() throws {
        // Absent block decodes to nil (all-default knobs) and re-encodes without it.
        let bare = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(bare.logSync == nil)

        var c = AppConfig()
        c.logSync = LogSyncConfig(retentionDays: 14)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.logSync == c.logSync)
    }
}

/// Since CROW-1070 the `logSync` block holds only behavior knobs — no credential,
/// no opt-in — so it is an ordinary, browser-editable config block: NOT stripped
/// for transport and NOT restored from the stored config on a set-config
/// round-trip (unlike the gateways/tokens, which are).
@Suite struct LogSyncSecretsTests {
    @Test func blockIsNotStrippedForTransport() {
        var c = AppConfig()
        c.logSync = LogSyncConfig(retentionDays: 14, quietPeriodMinutes: 10, maxUploadBytes: 1_000_000)
        let stripped = SettingsSecrets.strippedForTransport(c)
        // The knobs reach the browser intact — there is nothing secret to blank.
        #expect(stripped.logSync == c.logSync)
    }

    @Test func setConfigCanChangeLogSync() {
        var stored = AppConfig()
        stored.logSync = LogSyncConfig(retentionDays: 30)
        // The browser edits a knob and saves — the incoming value wins (the block
        // is not restored from `current`).
        var incoming = AppConfig()
        incoming.logSync = LogSyncConfig(retentionDays: 90, quietPeriodMinutes: 5)
        let result = SettingsSecrets.preservingSecrets(incoming: incoming, current: stored)
        #expect(result.logSync == incoming.logSync)
    }

    @Test func roundTripPreservesKnobs() {
        var c = AppConfig()
        c.logSync = LogSyncConfig(retentionDays: 90, quietPeriodMinutes: 15, maxUploadBytes: 4_000_000)
        let restored = SettingsSecrets.preservingSecrets(
            incoming: SettingsSecrets.strippedForTransport(c), current: c)
        #expect(restored.logSync == c.logSync)
    }
}
