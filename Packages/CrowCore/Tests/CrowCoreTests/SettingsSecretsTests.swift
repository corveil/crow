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
}
