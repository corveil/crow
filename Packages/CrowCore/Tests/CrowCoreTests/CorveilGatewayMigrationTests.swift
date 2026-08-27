import Foundation
import Testing

@testable import CrowCore

/// Detection + link (adoption) of manual `x-citadel-api-key` gateways into the
/// first-class Corveil connection (CROW-1126).
@Suite struct CorveilGatewayMigrationTests {

    private static let header = CorveilConnection.gatewayAPIKeyHeader  // "x-citadel-api-key"

    /// A connection with one provisioned org whose stored secret is `secret`.
    private func connection(
        baseURL: String = "https://gw.corveil.example",
        orgID: String = "org-1",
        orgName: String = "Acme",
        keyID: String = "key-1",
        secret: String = "sk-citadel-AbCdEfGhIjKl"
    ) -> CorveilConnection {
        CorveilConnection(
            baseURL: baseURL,
            clientID: "cid",
            orgKeys: [CorveilOrgKey(orgID: orgID, orgName: orgName, keyID: keyID, keyPrefix: "sk-citadel-Ab")],
            orgKeySecrets: [orgID: secret],
            oauth: CorveilOAuthTokens(accessToken: "at"))
    }

    private func gateway(_ baseURL: String, _ value: String, header: String = header)
        -> WorkspaceGateway {
        WorkspaceGateway(baseURL: baseURL, customHeaders: [header: value])
    }

    // MARK: - Detect

    @Test func detectIgnoresGatewaysWithoutCitadelHeader() {
        var config = AppConfig()
        config.managerGateway = WorkspaceGateway(
            baseURL: "https://proxy.example", customHeaders: ["Authorization": "Bearer x"])
        config.workspaces = [WorkspaceInfo(id: UUID(), name: "ws", gateway: nil)]
        #expect(CorveilGatewayMigration.detect(config: config).isEmpty)
    }

    @Test func detectManualGatewayWithoutConnectionIsManual() {
        var config = AppConfig()
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "ws",
                gateway: gateway("https://gw.corveil.example", "sk-citadel-Plain")),
        ]
        let candidates = CorveilGatewayMigration.detect(config: config)
        #expect(candidates.count == 1)
        let candidate = candidates[0]
        #expect(candidate.target == .workspace("ws"))
        #expect(candidate.valueKind == .plaintext)
        if case .manual(let reason) = candidate.classification {
            #expect(reason.contains("corveil connect"))
        } else {
            Issue.record("expected manual, got \(candidate.classification)")
        }
    }

    @Test func detectOpReferenceIsManualEvenWithConnection() {
        var config = AppConfig()
        config.corveilConnection = connection()
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "ws",
                gateway: gateway("https://gw.corveil.example", "op://Vault/Citadel/key")),
        ]
        let candidate = CorveilGatewayMigration.detect(config: config)[0]
        #expect(candidate.valueKind == .opReference)
        // The op:// ref is shown verbatim (not a secret) as the prefix hint.
        #expect(candidate.keyPrefix == "op://Vault/Citadel/key")
        if case .manual(let reason) = candidate.classification {
            #expect(reason.contains("op://"))
        } else {
            Issue.record("expected manual op://, got \(candidate.classification)")
        }
    }

    @Test func detectBaseURLMismatchIsManual() {
        var config = AppConfig()
        config.corveilConnection = connection(baseURL: "https://gw.corveil.example")
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "ws",
                gateway: gateway("https://other.example", "sk-citadel-Xyz")),
        ]
        let candidate = CorveilGatewayMigration.detect(config: config)[0]
        if case .manual(let reason) = candidate.classification {
            #expect(reason.contains("doesn't match"))
        } else {
            Issue.record("expected manual mismatch, got \(candidate.classification)")
        }
    }

    @Test func detectLinkablePlaintextOnMatchingBaseURL() {
        var config = AppConfig()
        config.corveilConnection = connection(baseURL: "https://gw.corveil.example")
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "ws",
                gateway: gateway("https://gw.corveil.example", "sk-citadel-Foreign")),
        ]
        let candidate = CorveilGatewayMigration.detect(config: config)[0]
        #expect(candidate.classification == .linkable)
    }

    @Test func detectTreatsTrailingSlashAsSameBaseURL() {
        var config = AppConfig()
        // Connection base has no trailing slash; the manual gateway typed one — the
        // same host two ways. It must read as linkable, not a "doesn't match" manual.
        config.corveilConnection = connection(baseURL: "https://gw.corveil.example")
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "ws",
                gateway: gateway("https://gw.corveil.example/", "sk-citadel-Foreign")),
        ]
        #expect(CorveilGatewayMigration.detect(config: config)[0].classification == .linkable)
    }

    @Test func detectManagedWhenGatewayEqualsDerived() {
        let secret = "sk-citadel-AbCdEfGhIjKl"
        var config = AppConfig()
        config.corveilConnection = connection(
            baseURL: "https://gw.corveil.example", orgID: "org-1", orgName: "Acme", secret: secret)
        // The workspace gateway is exactly what derivedGateway(org-1) produces.
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "ws",
                gateway: gateway("https://gw.corveil.example", secret)),
        ]
        let candidate = CorveilGatewayMigration.detect(config: config)[0]
        #expect(candidate.classification == .managed(orgID: "org-1", orgName: "Acme"))
    }

    @Test func detectMatchesHeaderCaseInsensitivelyAndRedactsBearer() {
        var config = AppConfig()
        config.corveilConnection = connection(baseURL: "https://gw.corveil.example")
        config.managerGateway = gateway(
            "https://gw.corveil.example", "Bearer sk-citadel-VeryLongSecretValue",
            header: "X-Citadel-Api-Key")
        let candidates = CorveilGatewayMigration.detect(config: config)
        #expect(candidates.count == 1)
        #expect(candidates[0].target == .manager)
        #expect(candidates[0].targetName == "Manager")
        // "Bearer " stripped, then truncated to 14 chars with an ellipsis — no secret dump.
        #expect(candidates[0].keyPrefix == "sk-citadel-Ver…")
    }

    @Test func detectListsManagerFirstThenWorkspaces() {
        var config = AppConfig()
        config.corveilConnection = connection()
        config.managerGateway = gateway("https://gw.corveil.example", "sk-citadel-M")
        config.workspaces = [
            WorkspaceInfo(id: UUID(), name: "ws", gateway: gateway("https://gw.corveil.example", "sk-citadel-W")),
        ]
        let targets = CorveilGatewayMigration.detect(config: config).map(\.target)
        #expect(targets == [.manager, .workspace("ws")])
    }

    // MARK: - Link (adopt)

    @Test func linkAdoptsPlaintextKeyIntoConnection() throws {
        var config = AppConfig()
        config.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example", clientID: "cid",
            oauth: CorveilOAuthTokens(accessToken: "at"))  // connected, no org yet
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "MyOrg",
                gateway: gateway("https://gw.corveil.example", "sk-citadel-Adopted")),
        ]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let orgKey = try CorveilGatewayMigration.link(
            config: &config, target: .workspace("myorg"),  // case-insensitive match
            orgID: "org-9", orgName: "My Org", now: now)

        #expect(orgKey.orgID == "org-9")
        #expect(orgKey.orgName == "My Org")
        #expect(orgKey.keyID == "")  // adopted, not minted
        #expect(orgKey.createdAt == now)

        let conn = try #require(config.corveilConnection)
        #expect(conn.orgKeySecrets["org-9"] == "sk-citadel-Adopted")
        #expect(conn.orgKeys.contains { $0.orgID == "org-9" })
        // Round-trip: the adopted org now derives the same gateway, so detect calls it managed.
        let candidate = CorveilGatewayMigration.detect(config: config)[0]
        #expect(candidate.classification == .managed(orgID: "org-9", orgName: "My Org"))
    }

    @Test func linkManagerTarget() throws {
        var config = AppConfig()
        config.corveilConnection = CorveilConnection(
            baseURL: "https://gw.corveil.example", clientID: "cid",
            oauth: CorveilOAuthTokens(accessToken: "at"))
        config.managerGateway = gateway("https://gw.corveil.example", "sk-citadel-Mgr")
        let orgKey = try CorveilGatewayMigration.link(
            config: &config, target: .manager, orgID: "org-m", orgName: nil)
        #expect(config.corveilConnection?.orgKeySecrets["org-m"] == "sk-citadel-Mgr")
        #expect(orgKey.orgName == "")  // no name given, none stored
    }

    @Test func linkRequiresConnection() {
        var config = AppConfig()
        config.managerGateway = gateway("https://gw.corveil.example", "sk-citadel-x")
        #expect(throws: CorveilGatewayMigration.LinkError.notConnected) {
            try CorveilGatewayMigration.link(config: &config, target: .manager, orgID: "o", orgName: nil)
        }
    }

    @Test func linkRejectsUnknownWorkspace() {
        var config = AppConfig()
        config.corveilConnection = connection()
        #expect(throws: CorveilGatewayMigration.LinkError.unknownTarget("nope")) {
            try CorveilGatewayMigration.link(
                config: &config, target: .workspace("nope"), orgID: "o", orgName: nil)
        }
    }

    @Test func linkRejectsTargetWithoutCitadelGateway() {
        var config = AppConfig()
        config.corveilConnection = connection()
        config.workspaces = [
            WorkspaceInfo(
                id: UUID(), name: "ws",
                gateway: WorkspaceGateway(baseURL: "https://x", customHeaders: ["Authorization": "Bearer y"])),
        ]
        #expect(throws: CorveilGatewayMigration.LinkError.noCitadelGateway) {
            try CorveilGatewayMigration.link(
                config: &config, target: .workspace("ws"), orgID: "o", orgName: nil)
        }
    }

    @Test func linkRejectsOpReference() {
        var config = AppConfig()
        config.corveilConnection = connection()
        config.managerGateway = gateway("https://gw.corveil.example", "op://Vault/Citadel/key")
        #expect(throws: CorveilGatewayMigration.LinkError.notPlaintext) {
            try CorveilGatewayMigration.link(config: &config, target: .manager, orgID: "o", orgName: nil)
        }
    }

    @Test func linkRequiresOrgID() {
        var config = AppConfig()
        config.corveilConnection = connection()
        config.managerGateway = gateway("https://gw.corveil.example", "sk-citadel-x")
        #expect(throws: CorveilGatewayMigration.LinkError.orgRequired) {
            try CorveilGatewayMigration.link(config: &config, target: .manager, orgID: "  ", orgName: nil)
        }
    }

    @Test func linkRefusesToOverwriteMintedKey() {
        var config = AppConfig()
        // org-1 already has a MINTED key (non-empty keyID) — overwriting it would
        // strand a live key on Corveil, so link refuses and points at deselect-org.
        config.corveilConnection = connection(orgID: "org-1", keyID: "minted-key")
        config.managerGateway = gateway("https://gw.corveil.example", "sk-citadel-New")
        #expect(throws: CorveilGatewayMigration.LinkError.orgAlreadyProvisioned(orgID: "org-1")) {
            try CorveilGatewayMigration.link(config: &config, target: .manager, orgID: "org-1", orgName: nil)
        }
    }

    @Test func linkAllowsReAdoptingAnAdoptedKey() throws {
        var config = AppConfig()
        // org-1 has an ADOPTED key (empty keyID) — no server-side handle to strand,
        // so re-adopting (e.g. the manual key rotated) is allowed, no --force needed.
        config.corveilConnection = connection(orgID: "org-1", keyID: "", secret: "sk-citadel-Old")
        config.managerGateway = gateway("https://gw.corveil.example", "sk-citadel-New")
        try CorveilGatewayMigration.link(config: &config, target: .manager, orgID: "org-1", orgName: nil)
        #expect(config.corveilConnection?.orgKeySecrets["org-1"] == "sk-citadel-New")
        #expect(config.corveilConnection?.orgKeys.filter { $0.orgID == "org-1" }.count == 1)
    }

    @Test func linkRefusesBaseURLMismatch() {
        var config = AppConfig()
        config.corveilConnection = connection(baseURL: "https://gw.corveil.example")
        // The gateway points at a DIFFERENT host than the connection — detect calls
        // this `.manual`, and link must refuse it: derivedGateway would send the
        // adopted key to the connection's host, not this one.
        config.managerGateway = gateway("https://other.example", "sk-citadel-Foreign")
        #expect(throws: CorveilGatewayMigration.LinkError.baseURLMismatch(
            gateway: "https://other.example", connection: "https://gw.corveil.example")) {
            try CorveilGatewayMigration.link(config: &config, target: .manager, orgID: "org-9", orgName: nil)
        }
    }

    @Test func linkAcceptsTrailingSlashBaseURL() throws {
        var config = AppConfig()
        config.corveilConnection = connection(baseURL: "https://gw.corveil.example")
        // A trailing slash is the same host — link normalizes it, like detect does.
        config.managerGateway = gateway("https://gw.corveil.example/", "sk-citadel-Slash")
        try CorveilGatewayMigration.link(config: &config, target: .manager, orgID: "org-2", orgName: nil)
        #expect(config.corveilConnection?.orgKeySecrets["org-2"] == "sk-citadel-Slash")
    }
}
