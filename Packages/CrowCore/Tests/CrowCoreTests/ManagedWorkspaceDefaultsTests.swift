import Foundation
import Testing
import CrowCore

/// Unit coverage for the managed / design-partner workspace creation defaults
/// (CROW-2841): the pure resolution of "is this install managed, and which org
/// gateway does a new workspace bind to?" plus the field application. The
/// end-to-end wiring through `workspace-add` / `set-config` is pinned separately in
/// `CrowDaemonTests.ManagedWorkspaceDefaultsHandlerTests`.
@Suite struct ManagedWorkspaceDefaultsTests {
    private let orgGateway = WorkspaceGateway(
        baseURL: "https://gw.corveil.example",
        customHeaders: ["x-citadel-api-key": "sk-citadel-key0"])

    /// A connected install with `orgCount` provisioned orgs, each with a usable key.
    private func managed(orgCount: Int) -> AppConfig {
        var c = AppConfig()
        c.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example",
            clientID: "cid",
            orgKeys: (0..<orgCount).map { CorveilOrgKey(orgID: "org-\($0)", orgName: "Org \($0)") },
            orgKeySecrets: Dictionary(
                uniqueKeysWithValues: (0..<orgCount).map { ("org-\($0)", "sk-citadel-key\($0)") }),
            oauth: CorveilOAuthTokens(accessToken: "at"))
        return c
    }

    // MARK: - managedWorkspaceGateway

    @Test func ossInstallHasNoManagedGateway() {
        // No Corveil connection at all — the self-hosted OSS case the ticket
        // preserves untouched.
        #expect(AppConfig().managedWorkspaceGateway() == nil)
    }

    @Test func singleProvisionedOrgYieldsItsDerivedGateway() throws {
        let gateway = try #require(managed(orgCount: 1).managedWorkspaceGateway())
        #expect(gateway.baseURL == "https://gw.corveil.example")
        #expect(gateway.customHeaders == ["x-citadel-api-key": "sk-citadel-key0"])
    }

    @Test func zeroProvisionedOrgsIsNotManaged() {
        // Connected, but no org key minted yet — there is no gateway to bind, and
        // log-sync without one would upload nothing.
        var c = AppConfig()
        c.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example", clientID: "cid",
            oauth: CorveilOAuthTokens(accessToken: "at"))
        #expect(c.managedWorkspaceGateway() == nil)
    }

    @Test func multipleProvisionedOrgsAreAmbiguous() {
        // Binding the wrong org would route a customer's traffic through another's
        // gateway, so we refuse to guess.
        #expect(managed(orgCount: 2).managedWorkspaceGateway() == nil)
    }

    @Test func orgWithoutAStoredKeyIsNotDerivable() {
        // Metadata present but no `sk-citadel-…` secret → no derivable gateway.
        var c = AppConfig()
        c.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example", clientID: "cid",
            orgKeys: [CorveilOrgKey(orgID: "org-0", orgName: "Org 0")],
            orgKeySecrets: [:],
            oauth: CorveilOAuthTokens(accessToken: "at"))
        #expect(c.managedWorkspaceGateway() == nil)
    }

    @Test func oneDerivableOrgAmongUnprovisionedOnesStillResolves() throws {
        // Two org rows, only one carries a stored key → unambiguous.
        var c = AppConfig()
        c.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example", clientID: "cid",
            orgKeys: [CorveilOrgKey(orgID: "org-0", orgName: "A"),
                      CorveilOrgKey(orgID: "org-1", orgName: "B")],
            orgKeySecrets: ["org-1": "sk-citadel-only"],
            oauth: CorveilOAuthTokens(accessToken: "at"))
        let gateway = try #require(c.managedWorkspaceGateway())
        #expect(gateway.customHeaders == ["x-citadel-api-key": "sk-citadel-only"])
    }

    // MARK: - apply (single workspace)

    @Test func applyBindsGatewayAndEnablesUpload() {
        var ws = WorkspaceInfo(name: "Acme")
        let changed = ManagedWorkspaceDefaults.apply(
            to: &ws, gateway: orgGateway, enableUpload: true)
        #expect(changed)
        #expect(ws.gateway == orgGateway)
        #expect(ws.uploadSessionLogs)
    }

    @Test func applyHonorsExplicitUploadOptOutButStillBindsGateway() {
        // #11 (gateway) and #23 (log-sync) are distinct audit items: opting out of
        // upload must not also unbind the gateway.
        var ws = WorkspaceInfo(name: "Acme")
        ManagedWorkspaceDefaults.apply(to: &ws, gateway: orgGateway, enableUpload: false)
        #expect(ws.gateway == orgGateway)
        #expect(ws.uploadSessionLogs == false)
    }

    @Test func applyDoesNotClobberAnExistingGateway() {
        let existing = WorkspaceGateway(baseURL: "https://other", customHeaders: ["X": "y"])
        var ws = WorkspaceInfo(name: "Acme", gateway: existing)
        ManagedWorkspaceDefaults.apply(to: &ws, gateway: orgGateway, enableUpload: true)
        #expect(ws.gateway == existing)
        #expect(ws.uploadSessionLogs)
    }

    // MARK: - applyToNewWorkspaces (set-config path)

    @Test func newWorkspacesGetDefaultsExistingOnesAreUntouched() {
        var config = managed(orgCount: 1)
        let existing = WorkspaceInfo(name: "Existing")  // no gateway, upload off
        let brandNew = WorkspaceInfo(name: "New")
        config.workspaces = [existing, brandNew]

        ManagedWorkspaceDefaults.applyToNewWorkspaces(
            in: &config, previousWorkspaceIDs: [existing.id])

        let after = Dictionary(uniqueKeysWithValues: config.workspaces.map { ($0.name, $0) })
        #expect(after["Existing"]?.gateway == nil)
        #expect(after["Existing"]?.uploadSessionLogs == false)
        #expect(after["New"]?.gateway?.customHeaders == ["x-citadel-api-key": "sk-citadel-key0"])
        #expect(after["New"]?.uploadSessionLogs == true)
    }

    @Test func applyToNewWorkspacesIsNoOpForOSS() {
        var config = AppConfig()
        config.workspaces = [WorkspaceInfo(name: "New")]
        ManagedWorkspaceDefaults.applyToNewWorkspaces(in: &config, previousWorkspaceIDs: [])
        #expect(config.workspaces[0].gateway == nil)
        #expect(config.workspaces[0].uploadSessionLogs == false)
    }
}
