import ArgumentParser
import CrowCore
import CrowIPC
import Foundation
import Testing

@testable import CrowCLILib

/// Argument handling for `crow corveil` (CROW-1011). No daemon required — these
/// exercise `parseAsRoot` and the params the verbs would send.
@Suite("crow corveil command parsing")
struct CorveilCommandParsingTests {

    private func parse(_ arguments: [String]) throws -> ParsableCommand {
        try CrowCommand.parseAsRoot(arguments)
    }

    // MARK: - Registration

    @Test("The corveil verb group is registered with its subcommands")
    func registered() throws {
        #expect(CrowCommand.configuration.subcommands.contains { $0 == Corveil.self })
        let names = Corveil.configuration.subcommands.map { $0.configuration.commandName }
        #expect(Set(names) == [
            "verify", "reinstall-skill", "connect", "status", "disconnect", "orgs",
            "list-orgs", "select-org", "deselect-org", "detect-gateways", "link-gateway",
        ])
    }

    // MARK: - Connection (CROW-1120)

    @Test("connect maps its flags to snake_case params and drops blanks")
    func connectMapsFlags() throws {
        let connect = try #require(try parse([
            "corveil", "connect",
            "--base-url", "https://corveil.example.com",
            "--client-id", "crow-client-1",
            "--user-email", "dev@example.com",
            "--access-token", "at-secret",
            "--access-token-expires-at", "2026-01-01T00:00:00Z",
        ]) as? CorveilConnect)
        let params = connect.params
        #expect(params["base_url"]?.stringValue == "https://corveil.example.com")
        #expect(params["client_id"]?.stringValue == "crow-client-1")
        #expect(params["user_email"]?.stringValue == "dev@example.com")
        #expect(params["access_token"]?.stringValue == "at-secret")
        #expect(params["access_token_expires_at"]?.stringValue == "2026-01-01T00:00:00Z")
        // Nothing sent for the flags that were omitted — a blank must not clear a
        // stored value.
        #expect(params["refresh_token"] == nil)
        #expect(params["user_name"] == nil)
    }

    @Test("connect with no flags sends no params, so the daemon rejects an empty write")
    func connectWithoutFlagsSendsNothing() throws {
        let connect = try #require(try parse(["corveil", "connect"]) as? CorveilConnect)
        #expect(connect.params.isEmpty)
    }

    @Test("The read/clear verbs parse and take no arguments")
    func readAndClearVerbsParse() throws {
        #expect((try parse(["corveil", "status"]) as? CorveilStatus) != nil)
        #expect((try parse(["corveil", "disconnect"]) as? CorveilDisconnect) != nil)
        #expect((try parse(["corveil", "orgs"]) as? CorveilOrgs) != nil)
    }

    // MARK: - Org provisioning (CROW-1121)

    @Test("list-orgs sends refresh only when the flag is set")
    func listOrgsRefreshFlag() throws {
        let plain = try #require(try parse(["corveil", "list-orgs"]) as? CorveilListOrgs)
        #expect(plain.refresh == false)

        let refreshed = try #require(
            try parse(["corveil", "list-orgs", "--refresh"]) as? CorveilListOrgs)
        #expect(refreshed.refresh == true)
    }

    @Test("select-org requires --org and maps optional name/rotate")
    func selectOrgFlags() throws {
        let minimal = try #require(
            try parse(["corveil", "select-org", "--org", "org-123"]) as? CorveilSelectOrg)
        #expect(minimal.org == "org-123")
        #expect(minimal.name == nil)
        #expect(minimal.rotate == false)

        let full = try #require(try parse([
            "corveil", "select-org", "--org", "org-123", "--name", "Acme Inc", "--rotate",
        ]) as? CorveilSelectOrg)
        #expect(full.org == "org-123")
        #expect(full.name == "Acme Inc")
        #expect(full.rotate == true)
    }

    @Test("select-org without --org is rejected")
    func selectOrgRequiresOrg() {
        #expect(throws: (any Error).self) { _ = try self.parse(["corveil", "select-org"]) }
    }

    @Test("deselect-org requires --org")
    func deselectOrgFlags() throws {
        let deselect = try #require(
            try parse(["corveil", "deselect-org", "--org", "org-9"]) as? CorveilDeselectOrg)
        #expect(deselect.org == "org-9")
        #expect(throws: (any Error).self) { _ = try self.parse(["corveil", "deselect-org"]) }
    }

    // MARK: - Gateway migration (CROW-1126)

    @Test("detect-gateways parses and takes no arguments")
    func detectGatewaysParses() throws {
        #expect((try parse(["corveil", "detect-gateways"]) as? CorveilDetectGateways) != nil)
    }

    @Test("link-gateway parses the workspace and manager forms")
    func linkGatewayFlags() throws {
        let workspace = try #require(try parse([
            "corveil", "link-gateway", "--workspace", "Acme", "--org", "org-1",
        ]) as? CorveilLinkGateway)
        #expect(workspace.workspace == "Acme")
        #expect(workspace.manager == false)
        #expect(workspace.org == "org-1")
        #expect(workspace.force == false)

        let manager = try #require(try parse([
            "corveil", "link-gateway", "--manager", "--org", "org-1", "--org-name", "Acme", "--force",
        ]) as? CorveilLinkGateway)
        #expect(manager.manager == true)
        #expect(manager.workspace == nil)
        #expect(manager.orgName == "Acme")
        #expect(manager.force == true)
    }

    @Test("link-gateway requires --org")
    func linkGatewayRequiresOrg() {
        #expect(throws: (any Error).self) {
            _ = try self.parse(["corveil", "link-gateway", "--manager"])
        }
    }

    // MARK: - --path

    @Test("Both verbs default to the configured binary by sending no path")
    func pathDefaultsToConfig() throws {
        // An omitted `--path` must send no `path` key at all: an empty string
        // would be a caller *choosing* the empty path, and the daemon would have
        // no way to tell that from "use what Settings has".
        let verify = try #require(try parse(["corveil", "verify"]) as? CorveilVerify)
        #expect(verify.pathOption.params.isEmpty)

        let reinstall = try #require(
            try parse(["corveil", "reinstall-skill"]) as? CorveilReinstallSkill)
        #expect(reinstall.pathOption.params.isEmpty)
    }

    @Test("An explicit --path is forwarded")
    func explicitPathIsForwarded() throws {
        let verify = try #require(
            try parse(["corveil", "verify", "--path", "/opt/corveil"]) as? CorveilVerify)
        #expect(verify.pathOption.params["path"]?.stringValue == "/opt/corveil")
    }

    @Test("A --path is trimmed, and a blank one falls through to config")
    func blankPathFallsThrough() throws {
        let padded = try #require(
            try parse(["corveil", "verify", "--path", "  /opt/corveil\n"]) as? CorveilVerify)
        #expect(padded.pathOption.params["path"]?.stringValue == "/opt/corveil")

        // `--path ""` is the shape a script produces from an unset variable. It
        // means "no override", not "run the empty string".
        let blank = try #require(
            try parse(["corveil", "verify", "--path", "   "]) as? CorveilVerify)
        #expect(blank.pathOption.params.isEmpty)
    }

    // MARK: - Rejections

    @Test("An unknown corveil subcommand is rejected")
    func unknownSubcommandIsRejected() {
        #expect(throws: (any Error).self) { _ = try self.parse(["corveil", "install"]) }
    }
}
