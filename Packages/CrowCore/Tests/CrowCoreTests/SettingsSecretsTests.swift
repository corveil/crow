import Foundation
import Testing
import CrowCore

/// Locks down the web-Settings credential handling (CROW-581): credentials are
/// desktop-only and read-only on the web, so the transport must (1) never ship a
/// secret value to the browser and (2) never let a web write change or clear a
/// stored secret. The load-bearing guarantee is the identity property: a
/// strip→preserve round trip with no edits is a no-op.
@Suite struct SettingsSecretsTests {
    /// A config carrying a value in every secret field, plus a couple of
    /// non-secret fields so we can prove those pass through untouched.
    private func configWithSecrets(workspaceID: UUID = UUID()) -> AppConfig {
        var c = AppConfig()
        c.remoteControlEnabled = true
        c.jiraCredential = JiraCredential(username: "me@corp.com", tokenRef: "op://vault/jira/token")
        c.managerGateway = WorkspaceGateway(
            baseURL: "https://gw.example",
            customHeaders: ["Authorization": "Bearer MANAGER-SECRET", "X-Extra": "plain-value"])
        c.workspaces = [
            WorkspaceInfo(
                id: workspaceID, name: "ws1",
                gateway: WorkspaceGateway(
                    baseURL: "https://ws.example",
                    customHeaders: ["Authorization": "Bearer WS-SECRET"])),
        ]
        c.mcpTokens = [
            MCPTokenRecord(
                name: "grok-bot", prefix: "AbCdEfGh", hashB64: "TE9DQUwtVE9LRU4tSEFTSA==",
                scopes: [.boardRead], expiresAt: Date(timeIntervalSince1970: 1_900_000_000)),
        ]
        return c
    }

    @Test func strippedBlanksValuesButKeepsStructure() {
        let stripped = SettingsSecrets.strippedForTransport(configWithSecrets())

        // Jira: username kept, token blanked.
        #expect(stripped.jiraCredential?.username == "me@corp.com")
        #expect(stripped.jiraCredential?.tokenRef == "")

        // Manager gateway: baseURL + header NAMES kept, all values blanked.
        #expect(stripped.managerGateway?.baseURL == "https://gw.example")
        #expect(Set(stripped.managerGateway?.customHeaders.keys ?? [:].keys) == ["Authorization", "X-Extra"])
        #expect(stripped.managerGateway?.customHeaders.values.allSatisfy { $0.isEmpty } == true)

        // Workspace gateway: same treatment.
        #expect(stripped.workspaces.first?.gateway?.baseURL == "https://ws.example")
        #expect(stripped.workspaces.first?.gateway?.customHeaders["Authorization"] == "")

        // Non-secret field untouched.
        #expect(stripped.remoteControlEnabled == true)
    }

    @Test func strippedConfigStillDecodes() throws {
        // Blanking only header VALUES (not names) must keep WorkspaceGateway's
        // both-or-neither decode invariant satisfied, so the stripped config
        // round-trips through JSON unchanged.
        let stripped = SettingsSecrets.strippedForTransport(configWithSecrets())
        let data = try JSONEncoder().encode(stripped)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == stripped)
    }

    @Test func preservingRestoresStoredSecretsAndKeepsNonSecretEdits() {
        let wsID = UUID()
        let current = configWithSecrets(workspaceID: wsID)

        // Simulate a browser: it received the stripped config, then edited a
        // non-secret field (a toggle) and a workspace name — but the credential
        // values are still blank (read-only in the UI).
        var incoming = SettingsSecrets.strippedForTransport(current)
        incoming.remoteControlEnabled = false
        incoming.workspaces[0].name = "ws1-renamed"

        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)

        // Secrets restored from the stored config.
        #expect(merged.jiraCredential == current.jiraCredential)
        #expect(merged.managerGateway == current.managerGateway)
        #expect(merged.workspaces.first?.gateway == current.workspaces.first?.gateway)
        // Non-secret edits survived.
        #expect(merged.remoteControlEnabled == false)
        #expect(merged.workspaces.first?.name == "ws1-renamed")
    }

    @Test func stripThenPreserveIsIdentity() {
        // The core guarantee: an untouched web round-trip never mutates config.
        let current = configWithSecrets()
        let merged = SettingsSecrets.preservingSecrets(
            incoming: SettingsSecrets.strippedForTransport(current), current: current)
        #expect(merged == current)
    }

    /// CROW-1066: the per-workspace `uploadSessionLogs` opt-in rides on the
    /// workspace record (not the local-only `logSync` block), so a browser edit of
    /// it must survive `preservingSecrets` — unlike the `logSync` block, which is
    /// always restored from `current`. This is the intended, bounded relaxation:
    /// the checkbox is browser-flippable; the credential and master switch are not.
    @Test func preservingKeepsBrowserToggleOfUploadSessionLogsButNotLogSyncBlock() {
        let wsID = UUID()
        var current = configWithSecrets(workspaceID: wsID)
        current.logSync = LogSyncConfig(enabled: true, baseURL: "https://api.corveil.io",
                                        apiKeyRef: "op://vault/corveil/key")

        var incoming = SettingsSecrets.strippedForTransport(current)
        incoming.workspaces[0].uploadSessionLogs = true  // browser ticks the checkbox
        // A browser trying to change the local-only master switch must be ignored.
        incoming.logSync = LogSyncConfig(enabled: true, baseURL: "https://evil.example",
                                         apiKeyRef: "evil", enabledWorkspaces: ["ws"])

        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
        #expect(merged.workspaces[0].uploadSessionLogs == true)  // browser edit kept
        #expect(merged.logSync == current.logSync)               // local-only block restored, not the browser's
    }

    @Test func preserveIgnoresBrowserCredentialEdits() {
        // A hostile/buggy client that tries to inject a new token or gateway must
        // be ignored: stored values always win.
        let current = configWithSecrets()
        var incoming = SettingsSecrets.strippedForTransport(current)
        incoming.jiraCredential = JiraCredential(username: "evil", tokenRef: "evil-token")
        incoming.managerGateway = WorkspaceGateway(
            baseURL: "https://evil.example", customHeaders: ["Authorization": "Bearer EVIL"])

        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
        #expect(merged.jiraCredential == current.jiraCredential)
        #expect(merged.managerGateway == current.managerGateway)
    }

    @Test func preserveWithNilCurrentDropsCredentials() {
        // App down and no config file yet: there's nothing to restore, so drop
        // any credential shell the browser echoed back rather than persist a
        // (blank) value.
        let incoming = SettingsSecrets.strippedForTransport(configWithSecrets())
        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: nil)
        #expect(merged.jiraCredential == nil)
        #expect(merged.managerGateway == nil)
        #expect(merged.workspaces.first?.gateway == nil)
    }

    // MARK: - MCP bearer tokens (CROW-1004)

    @Test func strippedBlanksMCPTokenHashesButKeepsRecords() {
        let stripped = SettingsSecrets.strippedForTransport(configWithSecrets())
        // The record survives so Settings can list and revoke it…
        #expect(stripped.mcpTokens.count == 1)
        #expect(stripped.mcpTokens[0].name == "grok-bot")
        #expect(stripped.mcpTokens[0].prefix == "AbCdEfGh")
        #expect(stripped.mcpTokens[0].scopes == [.boardRead])
        // …but nothing that could authenticate as it goes to the browser.
        #expect(stripped.mcpTokens[0].hashB64 == "")
    }

    @Test func strippedMCPTokenNeverAppearsInTheSerializedConfig() throws {
        let stripped = SettingsSecrets.strippedForTransport(configWithSecrets())
        let text = try #require(String(data: JSONEncoder().encode(stripped), encoding: .utf8))
        #expect(!text.contains("TE9DQUwtVE9LRU4tSEFTSA=="))
    }

    @Test func preserveIgnoresBrowserMintedMCPTokens() {
        // ⚠️ The attack this closes. `strippedForTransport` hands the token records
        // to an authenticated remote browser with blank hashes. If a returning
        // `set-config` were trusted, that peer could post back a record whose hash it
        // chose — minting itself a working bearer token for the very MCP surface the
        // token gates, without ever touching the local-only `mcp-token-mint`.
        let current = configWithSecrets()
        var incoming = SettingsSecrets.strippedForTransport(current)
        incoming.mcpTokens = [
            MCPTokenRecord(
                name: "attacker", prefix: "EEEEEEEE", hashB64: "RVZJTC1IQVNI",
                scopes: [.sessionsRead, .boardRead], expiresAt: nil),
        ]

        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
        #expect(merged.mcpTokens == current.mcpTokens)
        #expect(!merged.mcpTokens.contains { $0.name == "attacker" })
    }

    @Test func preserveIgnoresBrowserRevocationOfMCPTokens() {
        // The mirror image: a set-config that omits the tokens must not delete them.
        // Revocation is a local-only verb, not a side effect of saving Settings.
        let current = configWithSecrets()
        var incoming = SettingsSecrets.strippedForTransport(current)
        incoming.mcpTokens = []

        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
        #expect(merged.mcpTokens == current.mcpTokens)
    }

    @Test func preserveWithNilCurrentDropsMCPTokens() {
        // No stored config to restore from — drop whatever the browser echoed rather
        // than persist a token nobody minted.
        let incoming = SettingsSecrets.strippedForTransport(configWithSecrets())
        let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: nil)
        #expect(merged.mcpTokens.isEmpty)
    }
}
