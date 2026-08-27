import CrowCore
import CrowPersistence
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import CrowDaemon

/// The provisioning coordinator (CROW-1121): reuse-not-remint, rotate, revoke,
/// no-duplicate-keys, the org-list cache, and proactive token refresh — all
/// against stub API + OAuth transports over a temp devRoot.
@Suite struct CorveilOrgProvisionerTests {

    // MARK: - Fixtures

    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("corveil-prov-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private let base = "https://corveil.test"

    /// Seed a usable connection with a non-expired access token.
    private func seedConnection(
        devRoot: String,
        orgKeys: [CorveilOrgKey] = [],
        orgKeySecrets: [String: String] = [:],
        expiresAt: Date? = Date(timeIntervalSinceNow: 3600),
        refreshToken: String = "rt"
    ) throws {
        var config = AppConfig()
        config.corveilConnection = CorveilConnection(
            baseURL: base,
            clientID: "client-1",
            connectedUser: CorveilConnectedUser(id: "u1", email: "a@b.c", name: "A"),
            orgKeys: orgKeys,
            orgKeySecrets: orgKeySecrets,
            oauth: CorveilOAuthTokens(
                accessToken: "at", refreshToken: refreshToken,
                registrationAccessToken: "reg", accessTokenExpiresAt: expiresAt))
        try ConfigStore.saveConfig(config, devRoot: devRoot)
    }

    private func storedConnection(_ devRoot: String) -> CorveilConnection? {
        ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection
    }

    // MARK: - API stub

    /// Records requests and serves per-endpoint canned responses, so tests can
    /// count mints/revokes and assert reuse skipped the network. All state is
    /// mutated inside a synchronous, lock-guarded `handle` — the async transport
    /// closure only calls it (an `NSLock` cannot be taken from an async context).
    private final class APIStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _posts = 0
        private var _deletes = 0
        private var _lists = 0
        private var _lastBearer: String?
        private var mintCounter = 0

        var posts: Int { lock.lock(); defer { lock.unlock() }; return _posts }
        var deletes: Int { lock.lock(); defer { lock.unlock() }; return _deletes }
        var lists: Int { lock.lock(); defer { lock.unlock() }; return _lists }
        var lastBearer: String? { lock.lock(); defer { lock.unlock() }; return _lastBearer }

        private func handle(_ request: URLRequest) -> (Int, Data) {
            lock.lock(); defer { lock.unlock() }
            _lastBearer = request.value(forHTTPHeaderField: "Authorization")
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            var status = 200
            var body: [String: Any] = [:]
            if path.hasSuffix("/api/me/organizations") {
                _lists += 1
                body = ["organizations": [
                    ["organization_id": "org1", "organization_name": "Acme",
                     "role": "admin", "is_active": true],
                ]]
            } else if method == "POST", path.hasSuffix("/api/keys") {
                _posts += 1
                mintCounter += 1
                body = [
                    "id": "key-\(mintCounter)",
                    "key_prefix": "sk-citadel-p\(mintCounter)",
                    "key": "sk-citadel-secret-\(mintCounter)",
                    "created_at": "2026-01-02T03:04:05Z",
                ]
            } else if method == "DELETE" {
                _deletes += 1
                body = ["status": "ok", "message": "revoked"]
            } else {
                status = 404
            }
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (status, data)
        }

        func client() -> CorveilAPIClient {
            CorveilAPIClient(transport: { request in
                let (status, data) = self.handle(request)
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                return (data, response)
            })
        }
    }

    /// An OAuth client stub that answers the refresh (token) endpoint. Records
    /// whether it was called so the "refresh only when expired" path is testable.
    private final class OAuthStub: @unchecked Sendable {
        private let lock = NSLock()
        private var _refreshed = 0
        var refreshed: Int { lock.lock(); defer { lock.unlock() }; return _refreshed }

        private func recordAndBody() -> Data {
            lock.lock(); defer { lock.unlock() }
            _refreshed += 1
            let body: [String: Any] = [
                "access_token": "refreshed-at", "refresh_token": "new-rt",
                "token_type": "Bearer", "expires_in": 3600,
            ]
            return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }

        func client() -> CorveilOAuthClient {
            CorveilOAuthClient(transport: { request in
                let data = self.recordAndBody()
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            })
        }
    }

    private func neverCalledOAuth() -> CorveilOAuthClient {
        CorveilOAuthClient(transport: { _ in
            Issue.record("OAuth refresh should not have been called")
            throw CorveilOAuthClient.Failure.transport("unexpected")
        })
    }

    /// A thread-safe counter for observing calls from an async transport closure
    /// (the lock is taken inside the synchronous `increment`, never from `async`).
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
        func increment() { lock.lock(); _value += 1; lock.unlock() }
    }

    // MARK: - Provision: mint

    @Test func provisionMintsAndStoresKeyPlusSecret() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)
        let api = APIStub()

        let outcome = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: "Acme", cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(outcome.reused == false)
        #expect(api.posts == 1)
        let conn = try #require(storedConnection(devRoot))
        #expect(conn.orgKeys.count == 1)
        #expect(conn.orgKeys.first?.orgID == "org1")
        #expect(conn.orgKeys.first?.keyID == "key-1")
        #expect(conn.orgKeys.first?.orgName == "Acme")
        // The secret is stored — and is the value the mint returned.
        #expect(conn.orgKeySecrets["org1"] == "sk-citadel-secret-1")
    }

    // MARK: - Provision: reuse (no duplicate)

    @Test func provisionReusesExistingKeyWithoutMinting() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(
            devRoot: devRoot,
            orgKeys: [CorveilOrgKey(orgID: "org1", orgName: "Acme", keyID: "existing", keyPrefix: "sk-citadel-x")],
            orgKeySecrets: ["org1": "sk-citadel-existing-value"])
        let api = APIStub()

        // No `--name` given: a reuse must still make ZERO network calls — not even
        // the membership lookup — so it can't fail on a transient outage.
        let outcome = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: nil, cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(outcome.reused == true)
        #expect(outcome.orgKey.keyID == "existing")
        #expect(api.posts == 0, "reuse must not mint a new key")
        #expect(api.lists == 0, "reuse must not even look up the org name")
        // Stored value is untouched — the shared key survives.
        #expect(storedConnection(devRoot)?.orgKeySecrets["org1"] == "sk-citadel-existing-value")
    }

    // MARK: - Provision: name resolution

    @Test func mintWithoutNameLooksUpTheOrgNameFromMemberships() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)
        let api = APIStub()

        let outcome = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: nil, cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(outcome.orgKey.orgName == "Acme", "name resolved from the membership list")
        #expect(api.lists == 1)
        #expect(api.posts == 1)
    }

    @Test func mintWithNameValidatesMembershipButUsesTheNameForDisplay() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)
        let api = APIStub()

        // A supplied `--name` is display-only: it overrides the stored name but does
        // NOT skip the membership validation.
        let outcome = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: "Custom Name", cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(outcome.orgKey.orgName == "Custom Name")
        #expect(api.lists == 1, "membership is always validated, even with a supplied name")
        #expect(api.posts == 1)
    }

    @Test func mintForANonMembershipThrowsWithoutMinting() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)

        // Both with and without a supplied name, an org the user doesn't belong to
        // is rejected locally and never minted — `--name` can't smuggle it past.
        for name in [String?.none, "Ghost Corp"] {
            let api = APIStub()  // memberships list only contains "org1"
            await #expect(throws: CorveilOrgProvisioner.ProvisionError.unknownOrg("ghost")) {
                _ = try await CorveilOrgProvisioner.provision(
                    devRoot: devRoot, orgID: "ghost", orgName: name, cache: CorveilOrgListCache(),
                    apiClient: api.client(), oauthClient: self.neverCalledOAuth())
            }
            #expect(api.posts == 0, "an org the user doesn't belong to is never minted")
        }
    }

    // MARK: - Provision: a concurrent write racing the mint

    /// Drive a `provision` whose mint, mid-flight (during the `POST /api/keys`),
    /// runs `midMint(devRoot)` to mutate the stored connection — simulating a
    /// concurrent disconnect or reconnect that lands in the window between mint and
    /// persist. Returns the error thrown (if any) and how many revoke DELETEs ran.
    private func provisionRacingAMint(
        devRoot: String,
        orgID: String = "org1",
        midMint: @escaping @Sendable (String) -> Void
    ) async -> (error: Error?, deletes: Int) {
        let deletes = Counter()
        let client = CorveilAPIClient(transport: { request in
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path ?? ""
            var status = 200
            var body: [String: Any] = [:]
            if path.hasSuffix("/api/me/organizations") {
                body = ["organizations": [[
                    "organization_id": "org1", "organization_name": "Acme",
                    "role": "admin", "is_active": true,
                ]]]
            } else if method == "POST", path.hasSuffix("/api/keys") {
                midMint(devRoot)  // the concurrent disconnect/reconnect lands here
                body = [
                    "id": "key-orphan", "key_prefix": "sk-citadel-orph",
                    "key": "sk-citadel-LEAKED", "created_at": "2026-01-02T03:04:05Z",
                ]
            } else if method == "DELETE" {
                deletes.increment()
                body = ["status": "ok", "message": "revoked"]
            } else {
                status = 404
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            return (data, response)
        })
        var thrown: Error?
        do {
            _ = try await CorveilOrgProvisioner.provision(
                devRoot: devRoot, orgID: orgID, orgName: "Acme", cache: CorveilOrgListCache(),
                apiClient: client, oauthClient: neverCalledOAuth())
        } catch {
            thrown = error
        }
        return (thrown, deletes.value)
    }

    @Test func disconnectDuringMintDoesNotResurrectTheConnectionOrLeakTheKey() async throws {
        // A `corveil-disconnect` clears the connection while the mint is in flight.
        // The freshly minted `sk-citadel-…` must NOT be written back onto a
        // resurrected zombie connection — it must be revoked and the select fail.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)

        let (error, deletes) = await provisionRacingAMint(devRoot: devRoot) { root in
            var cfg = ConfigStore.loadConfig(devRoot: root) ?? AppConfig()
            cfg.corveilConnection = nil
            try? ConfigStore.saveConfig(cfg, devRoot: root)
        }

        #expect(error as? CorveilOrgProvisioner.ProvisionError == .connectionChanged)
        // No zombie connection, and no spendable secret left on disk.
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection == nil)
        #expect(deletes == 1, "the orphaned key must be revoked when the write is refused")
    }

    @Test func reconnectAsADifferentAccountDuringMintDoesNotInheritTheKey() async throws {
        // The subtler race: a DIFFERENT account connects mid-mint (fresh DCR client
        // id). The nil-guard doesn't catch this — a different live connection is not
        // empty — so the write must also refuse on a client-id mismatch, or account
        // B inherits account A's minted key.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)  // mints under clientID "client-1"
        let baseURL = base

        let (error, deletes) = await provisionRacingAMint(devRoot: devRoot) { root in
            var cfg = ConfigStore.loadConfig(devRoot: root) ?? AppConfig()
            cfg.corveilConnection = CorveilConnection(
                baseURL: baseURL,
                clientID: "client-2",  // a fresh DCR registration — a different grant
                connectedUser: CorveilConnectedUser(id: "u2", email: "b@corp.com", name: "B"),
                oauth: CorveilOAuthTokens(
                    accessToken: "at2", refreshToken: "rt2",
                    accessTokenExpiresAt: Date(timeIntervalSinceNow: 3600)))
            try? ConfigStore.saveConfig(cfg, devRoot: root)
        }

        #expect(error as? CorveilOrgProvisioner.ProvisionError == .connectionChanged)
        let conn = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(conn.clientID == "client-2", "the reconnected account is left untouched")
        #expect(conn.orgKeys.isEmpty, "the other account's key metadata is not attached")
        #expect(
            conn.orgKeySecrets["org1"] == nil,
            "the minted secret never lands on a different connection")
        #expect(deletes == 1, "the orphaned key is revoked")
    }

    @Test func provisionTwiceKeepsExactlyOneKeyPerOrg() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)
        let api = APIStub()

        _ = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: "Acme", cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth())
        let second = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: "Acme", cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(second.reused == true)
        #expect(api.posts == 1, "the second select reuses, not re-mints")
        #expect(storedConnection(devRoot)?.orgKeys.count == 1)
    }

    // MARK: - Rotate

    @Test func provisionForceRotatesToAFreshKeyReplacingTheOld() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(
            devRoot: devRoot,
            orgKeys: [CorveilOrgKey(orgID: "org1", orgName: "Acme", keyID: "old", keyPrefix: "sk-citadel-old")],
            orgKeySecrets: ["org1": "sk-citadel-old-value"])
        let api = APIStub()

        let outcome = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: "Acme", cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth(), force: true)

        #expect(outcome.reused == false)
        #expect(api.posts == 1)
        let conn = try #require(storedConnection(devRoot))
        // Exactly one key, and it's the new one (the backend revokes the old on mint).
        #expect(conn.orgKeys.count == 1)
        #expect(conn.orgKeys.first?.keyID == "key-1")
        #expect(conn.orgKeySecrets["org1"] == "sk-citadel-secret-1")
    }

    // MARK: - Deprovision

    @Test func deprovisionRevokesAndRemoves() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(
            devRoot: devRoot,
            orgKeys: [CorveilOrgKey(orgID: "org1", orgName: "Acme", keyID: "key-1", keyPrefix: "sk-citadel-p1")],
            orgKeySecrets: ["org1": "sk-citadel-secret-1"])
        let api = APIStub()

        let removed = try await CorveilOrgProvisioner.deprovision(
            devRoot: devRoot, orgID: "org1",
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(removed == true)
        #expect(api.deletes == 1)
        let conn = try #require(storedConnection(devRoot))
        #expect(conn.orgKeys.isEmpty)
        #expect(conn.orgKeySecrets["org1"] == nil)
    }

    @Test func deprovisionOfUnprovisionedOrgIsANoOp() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)
        let api = APIStub()

        let removed = try await CorveilOrgProvisioner.deprovision(
            devRoot: devRoot, orgID: "org1",
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(removed == false)
        #expect(api.deletes == 0, "nothing to revoke")
    }

    // MARK: - Not connected

    @Test func provisionWithoutConnectionThrows() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // No connection seeded.
        await #expect(throws: CorveilOrgProvisioner.ProvisionError.notConnected) {
            _ = try await CorveilOrgProvisioner.provision(
                devRoot: devRoot, orgID: "org1", orgName: "Acme", cache: CorveilOrgListCache(),
                apiClient: APIStub().client(), oauthClient: self.neverCalledOAuth())
        }
    }

    // MARK: - List + cache

    @Test func listOrganizationsCachesWithinTTL() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)
        let api = APIStub()
        let cache = CorveilOrgListCache()

        let first = try await CorveilOrgProvisioner.listOrganizations(
            devRoot: devRoot, cache: cache, apiClient: api.client(), oauthClient: neverCalledOAuth())
        let second = try await CorveilOrgProvisioner.listOrganizations(
            devRoot: devRoot, cache: cache, apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(first == second)
        #expect(api.lists == 1, "the second list is served from cache")
    }

    @Test func listOrganizationsForceRefreshBypassesCache() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)
        let api = APIStub()
        let cache = CorveilOrgListCache()

        _ = try await CorveilOrgProvisioner.listOrganizations(
            devRoot: devRoot, cache: cache, apiClient: api.client(), oauthClient: neverCalledOAuth())
        _ = try await CorveilOrgProvisioner.listOrganizations(
            devRoot: devRoot, cache: cache, apiClient: api.client(),
            oauthClient: neverCalledOAuth(), forceRefresh: true)

        #expect(api.lists == 2)
    }

    @Test func expiredEntryIsAMiss() async throws {
        let cache = CorveilOrgListCache(ttl: 60)
        let now = Date()
        cache.set([.init(id: "org1", name: "Acme", role: "admin", isActive: true)], key: "k", now: now)
        #expect(cache.get(key: "k", now: now.addingTimeInterval(30)) != nil)
        #expect(cache.get(key: "k", now: now.addingTimeInterval(120)) == nil)
        // A different key never matches.
        #expect(cache.get(key: "other", now: now) == nil)
    }

    @Test func invalidateClearsTheEntry() {
        let cache = CorveilOrgListCache()
        cache.set([.init(id: "org1", name: "Acme", role: "admin", isActive: true)], key: "k")
        #expect(cache.get(key: "k") != nil)
        cache.invalidate()
        #expect(cache.get(key: "k") == nil, "invalidate must drop the entry (disconnect hook)")
    }

    @Test func orgCacheIsKeyedOnClientIdSoAReconnectMisses() async throws {
        // The browser Connect flow leaves `connectedUser.id` empty and self-registers
        // a FRESH client id per DCR. The cache must key on the client id, not the
        // (empty) user id — otherwise a disconnect + reconnect as a different account
        // on the same host would be served the previous user's memberships. This is
        // the Yellow finding's regression test.
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let cache = CorveilOrgListCache()
        let api = APIStub()

        func connect(clientID: String) throws {
            var config = AppConfig()
            config.corveilConnection = CorveilConnection(
                baseURL: base,
                clientID: clientID,
                connectedUser: CorveilConnectedUser(),  // empty, as after a browser Connect
                oauth: CorveilOAuthTokens(
                    accessToken: "at", refreshToken: "rt",
                    accessTokenExpiresAt: Date(timeIntervalSinceNow: 3600)))
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        }

        // Connect as client A → one fetch, cached.
        try connect(clientID: "client-A")
        _ = try await CorveilOrgProvisioner.listOrganizations(
            devRoot: devRoot, cache: cache, apiClient: api.client(), oauthClient: neverCalledOAuth())
        #expect(api.lists == 1)

        // Same client id (a plain token refresh keeps it) → cache hit, no new fetch.
        _ = try await CorveilOrgProvisioner.listOrganizations(
            devRoot: devRoot, cache: cache, apiClient: api.client(), oauthClient: neverCalledOAuth())
        #expect(api.lists == 1, "the same client id serves the cached list")

        // Reconnect as a DIFFERENT client id (fresh DCR, still-empty user id) → miss.
        try connect(clientID: "client-B")
        _ = try await CorveilOrgProvisioner.listOrganizations(
            devRoot: devRoot, cache: cache, apiClient: api.client(), oauthClient: neverCalledOAuth())
        #expect(
            api.lists == 2,
            "a fresh client id must miss the cache, not leak the prior account's orgs")
    }

    // MARK: - Token refresh

    @Test func expiredAccessTokenIsRefreshedBeforeProvisioning() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // Token already expired, but a refresh token is present.
        try seedConnection(devRoot: devRoot, expiresAt: Date(timeIntervalSinceNow: -10))
        let api = APIStub()
        let oauth = OAuthStub()

        _ = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: "Acme", cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: oauth.client())

        #expect(oauth.refreshed >= 1, "an expired token triggers a refresh")
        // The refreshed token was persisted and used as the bearer for the mint.
        #expect(storedConnection(devRoot)?.oauth.accessToken == "refreshed-at")
        #expect(api.lastBearer == "Bearer refreshed-at")
    }

    @Test func freshTokenIsNotRefreshed() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seedConnection(devRoot: devRoot)  // expires in an hour
        let api = APIStub()

        _ = try await CorveilOrgProvisioner.provision(
            devRoot: devRoot, orgID: "org1", orgName: "Acme", cache: CorveilOrgListCache(),
            apiClient: api.client(), oauthClient: neverCalledOAuth())

        #expect(api.lastBearer == "Bearer at")
    }
}
