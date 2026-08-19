import Foundation
import Testing
import CrowCore

@Suite struct LogSyncConfigTests {
    @Test func defaultsAreOff() {
        let c = LogSyncConfig()
        #expect(c.enabled == false)
        #expect(c.baseURL.isEmpty)
        #expect(c.apiKeyRef.isEmpty)
        #expect(c.enabledWorkspaces.isEmpty)
        #expect(c.retentionDays == 30)
        #expect(c.quietPeriodMinutes == 30)
        #expect(c.maxUploadBytes == 8_000_000)
    }

    @Test func uploadsWorkspaceIsCaseInsensitive() {
        let c = LogSyncConfig(enabledWorkspaces: ["Acme", "Corveil"])
        #expect(c.uploadsWorkspace("acme"))
        #expect(c.uploadsWorkspace("CORVEIL"))
        #expect(!c.uploadsWorkspace("other"))
    }

    @Test func codableRoundTrip() throws {
        let c = LogSyncConfig(
            enabled: true, baseURL: "https://api.corveil.io",
            apiKeyRef: "op://vault/corveil/key", enabledWorkspaces: ["ws1"],
            retentionDays: 14, quietPeriodMinutes: 10, maxUploadBytes: 1_000_000)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(LogSyncConfig.self, from: data)
        #expect(decoded == c)
    }

    @Test func tolerantDecodeOfPartialBlock() throws {
        // An older config.json with only some keys still decodes to defaults.
        let json = #"{"enabled": true, "baseURL": "https://x"}"#
        let decoded = try JSONDecoder().decode(LogSyncConfig.self, from: Data(json.utf8))
        #expect(decoded.enabled)
        #expect(decoded.baseURL == "https://x")
        #expect(decoded.retentionDays == 30) // defaulted
        #expect(decoded.maxUploadBytes == 8_000_000)
    }

    @Test func appConfigRoundTripsLogSyncAndDefaultsToNil() throws {
        // Absent block decodes to nil (collector inert) and re-encodes without it.
        let bare = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(bare.logSync == nil)

        var c = AppConfig()
        c.logSync = LogSyncConfig(enabled: true, baseURL: "https://api", apiKeyRef: "op://v/k")
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.logSync == c.logSync)
    }
}

/// The log-sync block is local-only: its API key is stripped for the browser and
/// the whole block is restored from the stored config on a set-config round-trip.
@Suite struct LogSyncSecretsTests {
    @Test func apiKeyStrippedForTransport() {
        var c = AppConfig()
        c.logSync = LogSyncConfig(enabled: true, baseURL: "https://api", apiKeyRef: "op://v/k",
                                  enabledWorkspaces: ["ws1"])
        let stripped = SettingsSecrets.strippedForTransport(c)
        #expect(stripped.logSync?.apiKeyRef == "")
        // Non-secret fields still visible read-only.
        #expect(stripped.logSync?.enabled == true)
        #expect(stripped.logSync?.baseURL == "https://api")
        #expect(stripped.logSync?.enabledWorkspaces == ["ws1"])
    }

    @Test func setConfigCannotChangeLogSync() {
        var stored = AppConfig()
        stored.logSync = LogSyncConfig(enabled: true, baseURL: "https://api",
                                       apiKeyRef: "op://v/k", enabledWorkspaces: ["ws1"])
        // A hostile/edited browser config trying to enable an extra workspace and
        // plant a plaintext key.
        var incoming = AppConfig()
        incoming.logSync = LogSyncConfig(enabled: true, baseURL: "https://evil",
                                         apiKeyRef: "plaintext-stolen",
                                         enabledWorkspaces: ["ws1", "ws2"])
        let result = SettingsSecrets.preservingSecrets(incoming: incoming, current: stored)
        #expect(result.logSync == stored.logSync) // stored wins entirely
    }

    @Test func roundTripIsNoOp() {
        var c = AppConfig()
        c.logSync = LogSyncConfig(enabled: true, baseURL: "https://api", apiKeyRef: "op://v/k")
        let restored = SettingsSecrets.preservingSecrets(
            incoming: SettingsSecrets.strippedForTransport(c), current: c)
        #expect(restored.logSync == c.logSync)
    }
}
