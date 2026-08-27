import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
import Foundation
import Testing

@testable import CrowDaemon

/// The `corveil-connect` / `corveil-status` / `corveil-disconnect` /
/// `corveil-orgs` RPC methods — the CLI's local-only write path for the Corveil
/// connection (CROW-1120).
///
/// These go through the real router and read back from disk, so they cover the
/// handlers, the secret-safe merge in `CorveilConnectionRPC`, and
/// `CorveilConnection`'s tolerant decode in one pass.
@Suite struct CorveilConnectionRPCTests {
    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-corveil-conn-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @MainActor private func router(devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    private func call(
        _ router: CommandRouter, _ method: String, _ params: [String: JSONValue] = [:]
    ) async -> JSONRPCResponse {
        await router.handle(request: JSONRPCRequest(id: 1, method: method, params: params))
    }

    @Test @MainActor func connectStatusDisconnectRoundTrip() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        // Nothing connected yet.
        let before = await call(router, "corveil-status")
        #expect(before.result?["connected"] == .bool(false))

        let connect = await call(router, "corveil-connect", [
            "base_url": .string("https://corveil.example.com"),
            "client_id": .string("crow-client-1"),
            "user_id": .string("u1"),
            "user_email": .string("dev@example.com"),
            "user_name": .string("Dev"),
            "access_token": .string("at-secret"),
            "refresh_token": .string("rt-secret"),
            "registration_access_token": .string("rat-secret"),
            "access_token_expires_at": .string("2026-01-01T00:00:00Z"),
        ])
        #expect(connect.error == nil)
        #expect(connect.result?["saved"] == .bool(true))
        #expect(connect.result?["connected"] == .bool(true))

        // It reached disk with the tokens intact.
        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(stored.baseURL == "https://corveil.example.com")
        #expect(stored.clientID == "crow-client-1")
        #expect(stored.connectedUser.email == "dev@example.com")
        #expect(stored.oauth.accessToken == "at-secret")
        #expect(stored.oauth.refreshToken == "rt-secret")
        #expect(stored.oauth.registrationAccessToken == "rat-secret")

        // Status reports health without ever handing back a token value.
        let status = await call(router, "corveil-status")
        #expect(status.result?["connected"] == .bool(true))
        #expect(status.result?["base_url"] == .string("https://corveil.example.com"))
        #expect(status.result?["client_id"] == .string("crow-client-1"))
        #expect(status.result?["org_count"] == .int(0))
        #expect(status.result?["has_access_token"] == .bool(true))
        #expect(status.result?["has_refresh_token"] == .bool(true))
        #expect(status.result?["has_registration_access_token"] == .bool(true))
        #expect(status.result?["access_token_expires_at"]?.stringValue?.isEmpty == false)
        // No secret anywhere in the payload.
        let flattened = "\(status.result ?? [:])"
        #expect(!flattened.contains("at-secret"))
        #expect(!flattened.contains("rt-secret"))
        #expect(!flattened.contains("rat-secret"))

        let disconnect = await call(router, "corveil-disconnect")
        #expect(disconnect.result?["saved"] == .bool(true))
        #expect(disconnect.result?["was_connected"] == .bool(true))
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil)
    }

    @Test @MainActor func connectRefreshPreservesStoredSecretsAndOrgKeys() async throws {
        // A refresh sends only a new access token + expiry; the refresh token,
        // registration token, identity and provisioned org keys must survive.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let seeded = CorveilConnection(
            baseURL: "https://corveil.example.com",
            clientID: "crow-client-1",
            connectedUser: CorveilConnectedUser(id: "u1", email: "dev@example.com", name: "Dev"),
            orgKeys: [
                CorveilOrgKey(
                    orgID: "org1", orgName: "Acme", keyID: "key1",
                    keyPrefix: "sk-citadel-AbC", createdAt: Date(timeIntervalSince1970: 1))
            ],
            oauth: CorveilOAuthTokens(
                accessToken: "at-old", refreshToken: "rt-keep",
                registrationAccessToken: "rat-keep"))
        try ConfigStore.saveConfig(AppConfig(corveilConnection: seeded), devRoot: devRoot)
        let router = router(devRoot: devRoot)

        let refresh = await call(router, "corveil-connect", [
            "access_token": .string("at-new"),
            "access_token_expires_at": .string("2027-06-01T12:00:00Z"),
        ])
        #expect(refresh.error == nil)

        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(stored.oauth.accessToken == "at-new")           // updated
        #expect(stored.oauth.refreshToken == "rt-keep")         // preserved
        #expect(stored.oauth.registrationAccessToken == "rat-keep")
        #expect(stored.clientID == "crow-client-1")             // preserved
        #expect(stored.connectedUser.email == "dev@example.com")
        #expect(stored.orgKeys.count == 1)                      // provisioning survives a refresh
        #expect(stored.orgKeys.first?.keyID == "key1")
    }

    @Test @MainActor func connectRejectsAnEmptyConnection() async throws {
        // No client id, no access token, nothing stored → not a connection.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let response = await call(router, "corveil-connect", [
            "base_url": .string("https://corveil.example.com"),
        ])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil)
    }

    @Test @MainActor func connectRejectsAHalfFilledConnection() async throws {
        // The reviewer's reproduction: a client-id-only (or token-only) connect
        // must not be stored as a live-but-broken connection (CROW-1120 review).
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let clientOnly = await call(router, "corveil-connect", ["client_id": .string("crow-client-1")])
        #expect(clientOnly.error?.code == RPCErrorCode.invalidParams)

        let tokenOnly = await call(router, "corveil-connect", ["access_token": .string("at")])
        #expect(tokenOnly.error?.code == RPCErrorCode.invalidParams)

        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil)
    }

    @Test @MainActor func connectRejectsMalformedExpiry() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let response = await call(router, "corveil-connect", [
            "client_id": .string("crow-client-1"),
            "access_token": .string("at"),
            "access_token_expires_at": .string("not-a-date"),
        ])
        #expect(response.error?.code == RPCErrorCode.invalidParams)
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil)
    }

    @Test @MainActor func orgsListsStoredKeysWithoutKeyMaterial() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let connection = CorveilConnection(
            clientID: "crow-client-1",
            orgKeys: [
                CorveilOrgKey(orgID: "org1", orgName: "Acme", keyID: "key1", keyPrefix: "sk-citadel-AbC"),
                CorveilOrgKey(orgID: "org2", orgName: "Globex", keyID: "key2", keyPrefix: "sk-citadel-XyZ"),
            ],
            oauth: CorveilOAuthTokens(accessToken: "at"))
        try ConfigStore.saveConfig(AppConfig(corveilConnection: connection), devRoot: devRoot)
        let router = router(devRoot: devRoot)

        let orgs = await call(router, "corveil-orgs")
        #expect(orgs.result?["count"] == .int(2))
        let list = try #require(orgs.result?["orgs"]?.arrayValue)
        #expect(list.count == 2)
        #expect(list.first?.objectValue?["org_name"] == .string("Acme"))
        #expect(list.first?.objectValue?["key_prefix"] == .string("sk-citadel-AbC"))
    }

    @Test @MainActor func disconnectWhenNothingConnectedIsANoOpReceipt() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let router = router(devRoot: devRoot)

        let response = await call(router, "corveil-disconnect")
        #expect(response.result?["saved"] == .bool(true))
        #expect(response.result?["was_connected"] == .bool(false))
    }

    @Test @MainActor func connectRefusesToOverwriteAnUndecodableConfig() async throws {
        // Same guard as the gateway/web-password writers (CROW-814): a corrupt
        // config.json must not be silently replaced with defaults + a connection.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let claudeDir = (devRoot as NSString).appendingPathComponent(".claude")
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        let configPath = (claudeDir as NSString).appendingPathComponent("config.json")
        let corrupt = #"{"workspaces": "not-an-array"}"#
        try corrupt.write(toFile: configPath, atomically: true, encoding: .utf8)
        let router = router(devRoot: devRoot)

        let response = await call(router, "corveil-connect", [
            "client_id": .string("crow-client-1"),
            "access_token": .string("at"),
        ])
        #expect(response.error?.code == RPCErrorCode.applicationError)
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == corrupt)
    }
}

/// Unit coverage for the decode / merge / encode helpers behind those handlers.
@Suite struct CorveilConnectionRPCSupportTests {
    @Test func mergeFreshSetsProvidedFields() throws {
        let input = CorveilConnectionRPC.Input(
            baseURL: "https://corveil.example.com",
            clientID: "crow-client-1",
            userEmail: "dev@example.com",
            accessToken: "at")
        let merged = try CorveilConnectionRPC.merge(input, into: nil)
        #expect(merged.baseURL == "https://corveil.example.com")
        #expect(merged.clientID == "crow-client-1")
        #expect(merged.connectedUser.email == "dev@example.com")
        #expect(merged.oauth.accessToken == "at")
        #expect(merged.orgKeys.isEmpty)
    }

    @Test func mergeBlankFieldsKeepStoredValues() throws {
        let stored = CorveilConnection(
            baseURL: "https://corveil.example.com",
            clientID: "crow-client-1",
            orgKeys: [CorveilOrgKey(orgID: "org1", keyID: "key1")],
            orgKeySecrets: ["org1": "sk-citadel-secret"],
            oauth: CorveilOAuthTokens(accessToken: "at-old", refreshToken: "rt-keep"))
        // Only a new access token; blanks/absent keep the rest.
        let input = CorveilConnectionRPC.Input(accessToken: "at-new")
        let merged = try CorveilConnectionRPC.merge(input, into: stored)
        #expect(merged.oauth.accessToken == "at-new")
        #expect(merged.oauth.refreshToken == "rt-keep")
        #expect(merged.clientID == "crow-client-1")
        #expect(merged.orgKeys.count == 1)
        // A token refresh through this door must NOT drop the provisioned per-org
        // key metadata or its secret (corveil/crow#1121).
        #expect(merged.orgKeySecrets["org1"] == "sk-citadel-secret")
    }

    @Test func mergeRequiresBothClientIdAndAccessToken() {
        // `CorveilConnection.isEmpty` is an AND, so a half-filled connection is not
        // "empty" — but it is not usable either. The merge must reject any result
        // missing a client id or an access token, matching the error/CLI/docs.
        let cases: [CorveilConnectionRPC.Input] = [
            CorveilConnectionRPC.Input(),                                         // neither
            CorveilConnectionRPC.Input(baseURL: "https://corveil.example.com"),   // base URL only
            CorveilConnectionRPC.Input(clientID: "crow-client-1"),               // client id only
            CorveilConnectionRPC.Input(accessToken: "at"),                        // token only
        ]
        for input in cases {
            #expect(throws: CorveilConnectionRPC.Invalid.self) {
                _ = try CorveilConnectionRPC.merge(input, into: nil)
            }
        }
        // Both → accepted.
        let ok = try? CorveilConnectionRPC.merge(
            CorveilConnectionRPC.Input(clientID: "crow-client-1", accessToken: "at"), into: nil)
        #expect(ok?.clientID == "crow-client-1")
        #expect(ok?.oauth.accessToken == "at")
    }

    @Test func decodeInputParsesISOExpiryAndRejectsGarbage() throws {
        let input = try CorveilConnectionRPC.decodeInput([
            "client_id": .string("crow-client-1"),
            "access_token": .string("at"),
            "access_token_expires_at": .string("2026-01-01T00:00:00Z"),
        ])
        #expect(input.clientID == "crow-client-1")
        #expect(input.accessTokenExpiresAt != nil)

        #expect(throws: CorveilConnectionRPC.Invalid.self) {
            _ = try CorveilConnectionRPC.decodeInput([
                "access_token_expires_at": .string("nonsense"),
            ])
        }
    }

    @Test func expiryParsesBothPlainAndFractionalSeconds() throws {
        // A browser's `Date.toISOString()` emits milliseconds; both the plain shape
        // `statusJSON` writes and the fractional one must parse (CROW-1120 review).
        for stamp in ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00.000Z"] {
            #expect(try CorveilConnectionRPC.parseExpiry(stamp) != nil, "\(stamp) should parse")
        }
        // Absent / blank keeps the stored value (nil, no throw); garbage throws.
        #expect(try CorveilConnectionRPC.parseExpiry(nil) == nil)
        #expect(try CorveilConnectionRPC.parseExpiry("  ") == nil)
        #expect(throws: CorveilConnectionRPC.Invalid.self) {
            _ = try CorveilConnectionRPC.parseExpiry("2026-01-01")
        }
    }

    @Test func statusJSONReportsDisconnectedForNilAndEmpty() {
        #expect(CorveilConnectionRPC.statusJSON(nil)["connected"] == .bool(false))
        #expect(CorveilConnectionRPC.statusJSON(CorveilConnection())["connected"] == .bool(false))
        // Even disconnected, the shape carries the state fields the UI keys off.
        #expect(CorveilConnectionRPC.statusJSON(nil)["state"] == .string("disconnected"))
        #expect(CorveilConnectionRPC.statusJSON(nil)["needs_reconnect"] == .bool(false))
    }

    // A live connection whose token is comfortably in the future (CROW-1125).
    private func liveConnection(
        expiresAt: Date?, health: CorveilConnectionHealth = CorveilConnectionHealth()
    ) -> CorveilConnection {
        CorveilConnection(
            clientID: "crow-client-1",
            oauth: CorveilOAuthTokens(
                accessToken: "at", refreshToken: "rt", accessTokenExpiresAt: expiresAt),
            health: health)
    }

    @Test func statusJSONReportsConnectedStateWhenTokenIsFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = CorveilConnectionRPC.statusJSON(
            liveConnection(expiresAt: now.addingTimeInterval(3600)), now: now)
        #expect(json["state"] == .string("connected"))
        #expect(json["needs_reconnect"] == .bool(false))
    }

    @Test func statusJSONReportsExpiredStateOncePastExpiry() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = CorveilConnectionRPC.statusJSON(
            liveConnection(expiresAt: now.addingTimeInterval(-60)), now: now)
        #expect(json["state"] == .string("expired"))
        #expect(json["needs_reconnect"] == .bool(true))
    }

    @Test func statusJSONReportsRevokedWhenHealthLatchedIt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Revoked wins even though the clock hasn't reached expiry yet.
        let json = CorveilConnectionRPC.statusJSON(
            liveConnection(
                expiresAt: now.addingTimeInterval(3600),
                health: CorveilConnectionHealth(
                    lastRefreshError: "invalid_grant", needsReconnect: true)),
            now: now)
        #expect(json["state"] == .string("revoked"))
        #expect(json["needs_reconnect"] == .bool(true))
        #expect(json["last_refresh_error"] == .string("invalid_grant"))
    }

    @Test func statusJSONNeverExposesTokenValues() {
        let connection = CorveilConnection(
            clientID: "crow-client-1",
            oauth: CorveilOAuthTokens(
                accessToken: "at-secret", refreshToken: "rt-secret",
                registrationAccessToken: "rat-secret"))
        let json = CorveilConnectionRPC.statusJSON(connection)
        #expect(json["connected"] == .bool(true))
        #expect(json["has_access_token"] == .bool(true))
        let flattened = "\(json)"
        #expect(!flattened.contains("at-secret"))
        #expect(!flattened.contains("rt-secret"))
        #expect(!flattened.contains("rat-secret"))
    }

    @Test func orgsJSONMapsKeysAndEmptyForNil() {
        #expect(CorveilConnectionRPC.orgsJSON(nil)["count"] == .int(0))
        let connection = CorveilConnection(
            orgKeys: [CorveilOrgKey(orgID: "org1", orgName: "Acme", keyID: "key1", keyPrefix: "sk-citadel-AbC")])
        let json = CorveilConnectionRPC.orgsJSON(connection)
        #expect(json["count"] == .int(1))
        #expect(json["orgs"]?.arrayValue?.first?.objectValue?["org_id"] == .string("org1"))
    }
}
