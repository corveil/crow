import CrowCore
import CrowPersistence
import Foundation
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@testable import CrowDaemon

/// Unit coverage for the Corveil OAuth client and the state/persistence around it
/// (CROW-1119), driven entirely against a stub transport — no live Corveil. The
/// mounted-route behavior (gating, the loopback callback, end-to-end) lives in
/// ``CorveilIntegrationRouteTests``.
@Suite struct CorveilOAuthClientTests {

    // MARK: - Stub transport

    /// Records every request the client makes, in order, for assertions.
    private final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URLRequest] = []
        func append(_ request: URLRequest) { lock.lock(); items.append(request); lock.unlock() }
        var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return items }
        var last: URLRequest? { all.last }
    }

    /// A transport that maps each request to a `(status, jsonBody)` via `respond`,
    /// recording the request in `log`.
    private func transport(
        log: RequestLog? = nil,
        _ respond: @escaping @Sendable (URLRequest) -> (Int, Data)
    ) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            log?.append(request)
            let (status, body) = respond(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private func jsonData(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private func bodyString(_ request: URLRequest?) -> String {
        request?.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private let endpoints = CorveilOAuthClient.Endpoints(baseURL: "https://corveil.test")!

    // MARK: - PKCE (RFC 7636)

    @Test func pkceChallengeIsS256OfVerifier() {
        let pkce = CorveilOAuthClient.makePKCE()
        #expect(pkce.method == "S256")
        // 32 random bytes → 43 base64url chars (no padding).
        #expect(pkce.verifier.count == 43)
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        #expect(pkce.challenge.unicodeScalars.allSatisfy { allowed.contains($0) })
        // The challenge must be BASE64URL(SHA256(verifier)).
        #expect(pkce.challenge == CorveilOAuthClient.challenge(for: pkce.verifier))
    }

    /// The canonical PKCE S256 test vector from RFC 7636 Appendix B pins the
    /// challenge computation itself.
    @Test func s256MatchesRFC7636Vector() {
        #expect(CorveilOAuthClient.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func distinctPKCEEachCall() {
        #expect(CorveilOAuthClient.makePKCE().verifier != CorveilOAuthClient.makePKCE().verifier)
        #expect(CorveilOAuthClient.makeState() != CorveilOAuthClient.makeState())
    }

    // MARK: - Endpoints

    @Test func endpointsResolveAgainstBaseURL() {
        let withSlash = CorveilOAuthClient.Endpoints(baseURL: "https://corveil.test/")
        #expect(withSlash?.register.absoluteString == "https://corveil.test/mcp/oauth/register")
        #expect(withSlash?.authorize.absoluteString == "https://corveil.test/mcp/oauth/authorize")
        #expect(withSlash?.token.absoluteString == "https://corveil.test/mcp/oauth/token")
        // Without a trailing slash resolves identically.
        #expect(CorveilOAuthClient.Endpoints(baseURL: "https://corveil.test")?.token.absoluteString
            == "https://corveil.test/mcp/oauth/token")
    }

    @Test func endpointsRejectGarbageBaseURL() {
        #expect(CorveilOAuthClient.Endpoints(baseURL: "") == nil)
        #expect(CorveilOAuthClient.Endpoints(baseURL: "not-a-url") == nil)  // no scheme/host
    }

    @Test func endpointsRejectNonHTTPSchemes() {
        // A non-http(s) base URL is rejected before it can reach the browser or the
        // transport (review Green #1).
        #expect(CorveilOAuthClient.Endpoints(baseURL: "file://localhost/x") == nil)
        #expect(CorveilOAuthClient.Endpoints(baseURL: "javascript://alert.com") == nil)
        #expect(CorveilOAuthClient.Endpoints(baseURL: "slack://open") == nil)
        #expect(CorveilOAuthClient.Endpoints(baseURL: "http://corveil.test") != nil)  // http allowed (loopback dev)
    }

    // MARK: - Dynamic Client Registration (RFC 7591)

    @Test func registerParsesResponseAndSendsPublicClient() async throws {
        let log = RequestLog()
        let client = CorveilOAuthClient(transport: transport(log: log) { _ in
            (201, self.jsonData([
                "client_id": "crow-client-123",
                "registration_access_token": "reg-tok-abc",
                "registration_client_uri": "https://corveil.test/mcp/oauth/register/crow-client-123",
                "scope": "orgs.read keys.provision",
            ]))
        })

        let registration = try await client.register(
            endpoints: endpoints, redirectURI: "http://127.0.0.1:8787/integrations/corveil/callback")

        #expect(registration.clientID == "crow-client-123")
        #expect(registration.registrationAccessToken == "reg-tok-abc")
        #expect(registration.registrationClientURI.hasSuffix("/crow-client-123"))

        let request = try #require(log.last)
        #expect(request.url?.absoluteString == "https://corveil.test/mcp/oauth/register")
        #expect(request.httpMethod == "POST")
        // Public PKCE client with the loopback redirect + refresh grant.
        let sent = try #require(
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect(sent["token_endpoint_auth_method"] as? String == "none")
        #expect(sent["redirect_uris"] as? [String] == ["http://127.0.0.1:8787/integrations/corveil/callback"])
        #expect((sent["grant_types"] as? [String])?.contains("refresh_token") == true)
        #expect((sent["response_types"] as? [String]) == ["code"])
    }

    // MARK: - Authorize URL

    @Test func authorizeURLCarriesPKCEAndState() throws {
        let pkce = CorveilOAuthClient.makePKCE()
        let url = CorveilOAuthClient.authorizeURL(
            endpoints: endpoints, clientID: "cid", redirectURI: "http://127.0.0.1:8787/cb",
            scope: "orgs.read keys.provision", state: "st-123", pkce: pkce)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let map = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        #expect(url.absoluteString.hasPrefix("https://corveil.test/mcp/oauth/authorize?"))
        #expect(map["response_type"] == "code")
        #expect(map["client_id"] == "cid")
        #expect(map["redirect_uri"] == "http://127.0.0.1:8787/cb")
        #expect(map["scope"] == "orgs.read keys.provision")
        #expect(map["state"] == "st-123")
        #expect(map["code_challenge"] == pkce.challenge)
        #expect(map["code_challenge_method"] == "S256")
    }

    // MARK: - Token exchange (RFC 6749 §4.1.3)

    @Test func exchangeSendsFormAndParsesTokens() async throws {
        let log = RequestLog()
        let client = CorveilOAuthClient(transport: transport(log: log) { _ in
            (200, self.jsonData([
                "access_token": "at-1", "refresh_token": "rt-1",
                "token_type": "Bearer", "expires_in": 3600, "scope": "orgs.read",
            ]))
        })

        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = try await client.exchangeCode(
            endpoints: endpoints, clientID: "cid", code: "the-code",
            codeVerifier: "the-verifier", redirectURI: "http://127.0.0.1:8787/cb")

        #expect(tokens.accessToken == "at-1")
        #expect(tokens.refreshToken == "rt-1")
        #expect(tokens.expiresIn == 3600)
        #expect(tokens.expiresAt(now: now) == now.addingTimeInterval(3600))

        let request = try #require(log.last)
        #expect(request.url?.absoluteString == "https://corveil.test/mcp/oauth/token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let form = bodyString(request)
        #expect(form.contains("grant_type=authorization_code"))
        #expect(form.contains("code=the-code"))
        #expect(form.contains("code_verifier=the-verifier"))
        #expect(form.contains("client_id=cid"))
    }

    // MARK: - Refresh (RFC 6749 §6)

    @Test func refreshSendsRefreshGrant() async throws {
        let log = RequestLog()
        let client = CorveilOAuthClient(transport: transport(log: log) { _ in
            (200, self.jsonData([
                "access_token": "at-2", "refresh_token": "rt-2",
                "token_type": "Bearer", "expires_in": 3600, "scope": "orgs.read",
            ]))
        })

        let tokens = try await client.refresh(
            endpoints: endpoints, clientID: "cid", refreshToken: "rt-1")
        #expect(tokens.accessToken == "at-2")
        #expect(tokens.refreshToken == "rt-2")

        let form = bodyString(log.last)
        #expect(form.contains("grant_type=refresh_token"))
        #expect(form.contains("refresh_token=rt-1"))
        #expect(form.contains("client_id=cid"))
    }

    // MARK: - Error mapping

    @Test func oauthErrorBodyBecomesOAuthFailure() async {
        let client = CorveilOAuthClient(transport: transport { _ in
            (400, self.jsonData(["error": "invalid_grant", "error_description": "code expired"]))
        })
        await #expect(throws: CorveilOAuthClient.Failure.oauth(error: "invalid_grant", description: "code expired")) {
            _ = try await client.exchangeCode(
                endpoints: endpoints, clientID: "c", code: "x", codeVerifier: "v", redirectURI: "r")
        }
    }

    @Test func nonOAuthHTTPErrorBecomesHTTPFailure() async {
        let client = CorveilOAuthClient(transport: transport { _ in (500, Data("boom".utf8)) })
        await #expect(throws: CorveilOAuthClient.Failure.http(status: 500, body: "boom")) {
            _ = try await client.refresh(endpoints: endpoints, clientID: "c", refreshToken: "r")
        }
    }

    @Test func missingAccessTokenIsMalformed() async {
        let client = CorveilOAuthClient(transport: transport { _ in (200, self.jsonData(["scope": "x"])) })
        await #expect(throws: CorveilOAuthClient.Failure.self) {
            _ = try await client.exchangeCode(
                endpoints: endpoints, clientID: "c", code: "x", codeVerifier: "v", redirectURI: "r")
        }
    }

    @Test func expiresInOutOfRangeIsIgnoredNotFatal() async throws {
        // A 2xx token body with an out-of-Int-range `expires_in` (a buggy or hostile
        // AS) must not trap the daemon: the access token still parses and the expiry
        // is simply unknown (review Yellow).
        let client = CorveilOAuthClient(transport: transport { _ in
            (200, Data(#"{"access_token":"at","refresh_token":"rt","token_type":"Bearer","expires_in":1e20,"scope":"s"}"#.utf8))
        })
        let tokens = try await client.exchangeCode(
            endpoints: endpoints, clientID: "c", code: "x", codeVerifier: "v", redirectURI: "r")
        #expect(tokens.accessToken == "at")
        #expect(tokens.expiresIn == nil)
        #expect(tokens.expiresAt(now: Date()) == nil)
    }

    @Test func transportThrowBecomesTransportFailure() async {
        struct Boom: Error {}
        let client = CorveilOAuthClient(transport: { _ in throw Boom() })
        await #expect(throws: CorveilOAuthClient.Failure.self) {
            _ = try await client.register(endpoints: endpoints, redirectURI: "http://127.0.0.1/cb")
        }
    }

    // MARK: - Pending-auth store

    private func pending(state: String, at date: Date) -> CorveilPendingAuthorization {
        CorveilPendingAuthorization(
            state: state, codeVerifier: "v", clientID: "c", redirectURI: "r",
            baseURL: "https://corveil.test", registrationAccessToken: "reg", scope: "s", createdAt: date)
    }

    @Test func pendingStoreConsumeIsSingleUse() {
        let store = CorveilPendingAuthStore()
        let now = Date()
        store.put(pending(state: "abc", at: now))
        #expect(store.consume(state: "abc", now: now)?.codeVerifier == "v")
        // A second consume of the same state fails — no replay.
        #expect(store.consume(state: "abc", now: now) == nil)
    }

    @Test func pendingStoreRejectsUnknownAndExpired() {
        let store = CorveilPendingAuthStore(ttl: 60)
        let now = Date()
        #expect(store.consume(state: "never-issued", now: now) == nil)
        store.put(pending(state: "old", at: now.addingTimeInterval(-120)))
        #expect(store.consume(state: "old", now: now) == nil)  // past TTL
    }

    @Test func pendingStorePruneDropsExpired() {
        let store = CorveilPendingAuthStore(ttl: 60)
        let now = Date()
        store.put(pending(state: "fresh", at: now))
        store.put(pending(state: "stale", at: now.addingTimeInterval(-120)))
        store.prune(now: now)
        #expect(store.count == 1)
        #expect(store.consume(state: "fresh", now: now) != nil)
    }

    // MARK: - Persistence door

    private func tempDevRoot() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("corveil-oauth-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func storeThenUpdateTokensPreservesConnectionShell() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // A prior connect populated the connected user + org keys (a later step's job).
        var seeded = AppConfig()
        seeded.corveilConnection = CorveilConnection(
            baseURL: "https://old.test", clientID: "old",
            connectedUser: CorveilConnectedUser(id: "u1", email: "a@b.c", name: "A"),
            orgKeys: [CorveilOrgKey(orgID: "o1", orgName: "Org", keyID: "k1", keyPrefix: "sk-")])
        try ConfigStore.saveConfig(seeded, devRoot: devRoot)

        try CorveilConnectionPersistence.store(
            devRoot: devRoot, baseURL: "https://new.test", clientID: "new",
            tokens: CorveilOAuthTokens(accessToken: "at", refreshToken: "rt", registrationAccessToken: "reg"))

        let stored = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(stored.baseURL == "https://new.test")
        #expect(stored.clientID == "new")
        #expect(stored.oauth.accessToken == "at")
        // The connected user + org keys a reconnect must not destroy survive.
        #expect(stored.connectedUser.email == "a@b.c")
        #expect(stored.orgKeys.first?.keyID == "k1")

        // updateTokens replaces only the oauth block.
        let updated = try CorveilConnectionPersistence.updateTokens(
            devRoot: devRoot,
            tokens: CorveilOAuthTokens(accessToken: "at2", refreshToken: "rt2", registrationAccessToken: "reg"))
        #expect(updated)
        let after = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(after.oauth.accessToken == "at2")
        #expect(after.clientID == "new")  // untouched
    }

    @Test func updateTokensReturnsFalseWithoutConnection() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let updated = try CorveilConnectionPersistence.updateTokens(
            devRoot: devRoot, tokens: CorveilOAuthTokens(accessToken: "x"))
        #expect(!updated)
    }

    // MARK: - Refresher (load → refresh → store)

    @Test func refresherRenewsAndPersists() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        var seeded = AppConfig()
        seeded.corveilConnection = CorveilConnection(
            baseURL: "https://corveil.test", clientID: "cid",
            oauth: CorveilOAuthTokens(
                accessToken: "old-at", refreshToken: "old-rt", registrationAccessToken: "reg-keep"))
        try ConfigStore.saveConfig(seeded, devRoot: devRoot)

        let client = CorveilOAuthClient(transport: transport { _ in
            (200, self.jsonData([
                "access_token": "new-at", "refresh_token": "new-rt",
                "token_type": "Bearer", "expires_in": 3600, "scope": "orgs.read",
            ]))
        })
        let now = Date(timeIntervalSince1970: 2_000_000)
        let tokens = try await CorveilConnectionRefresher.refresh(devRoot: devRoot, client: client, now: now)

        #expect(tokens.accessToken == "new-at")
        #expect(tokens.refreshToken == "new-rt")
        #expect(tokens.registrationAccessToken == "reg-keep")  // not part of refresh, carried through
        #expect(tokens.accessTokenExpiresAt == now.addingTimeInterval(3600))
        // Persisted.
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection?.oauth.accessToken == "new-at")
    }

    @Test func refresherRejectsMissingConnectionAndToken() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // No connection at all.
        await #expect(throws: CorveilConnectionRefresher.RefreshError.self) {
            _ = try await CorveilConnectionRefresher.refresh(devRoot: devRoot)
        }
        // A connection with no refresh token.
        var seeded = AppConfig()
        seeded.corveilConnection = CorveilConnection(
            baseURL: "https://corveil.test", clientID: "cid",
            oauth: CorveilOAuthTokens(accessToken: "at", refreshToken: ""))
        try ConfigStore.saveConfig(seeded, devRoot: devRoot)
        await #expect(throws: CorveilConnectionRefresher.RefreshError.self) {
            _ = try await CorveilConnectionRefresher.refresh(devRoot: devRoot)
        }
    }

    @Test func mergedTokensKeepsRefreshWhenServerOmitsIt() {
        let existing = CorveilOAuthTokens(
            accessToken: "a", refreshToken: "keep-me", registrationAccessToken: "reg")
        let response = CorveilOAuthClient.TokenResponse(
            accessToken: "a2", refreshToken: "", tokenType: "Bearer", expiresIn: 60, scope: "s")
        let merged = CorveilConnectionRefresher.mergedTokens(
            existing: existing, response: response, now: Date(timeIntervalSince1970: 0))
        #expect(merged.accessToken == "a2")
        #expect(merged.refreshToken == "keep-me")  // server didn't rotate → keep old
        #expect(merged.registrationAccessToken == "reg")
    }

    // MARK: - Health persistence + reconnect state (CROW-1125)

    /// Seed a config with one connection whose token expires at `expiresAt`.
    private func seed(
        devRoot: String, expiresAt: Date?,
        refreshToken: String = "old-rt",
        health: CorveilConnectionHealth = CorveilConnectionHealth()
    ) throws {
        var config = AppConfig()
        config.corveilConnection = CorveilConnection(
            baseURL: "https://corveil.test", clientID: "cid",
            oauth: CorveilOAuthTokens(
                accessToken: "old-at", refreshToken: refreshToken,
                registrationAccessToken: "reg-keep", accessTokenExpiresAt: expiresAt),
            health: health)
        try ConfigStore.saveConfig(config, devRoot: devRoot)
    }

    private func storedHealth(_ devRoot: String) -> CorveilConnectionHealth? {
        ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection?.health
    }

    @Test func storeResetsHealthSoAReconnectClearsNeedsReconnect() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seed(
            devRoot: devRoot, expiresAt: Date(),
            health: CorveilConnectionHealth(lastRefreshError: "invalid_grant", needsReconnect: true))

        try CorveilConnectionPersistence.store(
            devRoot: devRoot, baseURL: "https://corveil.test", clientID: "cid",
            tokens: CorveilOAuthTokens(accessToken: "fresh", refreshToken: "fresh-rt"))

        let health = try #require(storedHealth(devRoot))
        #expect(!health.needsReconnect)
        #expect(health.lastRefreshError == nil)
    }

    @Test func recordRefreshSuccessStampsHealthy() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seed(
            devRoot: devRoot, expiresAt: Date(),
            health: CorveilConnectionHealth(lastRefreshError: "boom", needsReconnect: true))
        let now = Date(timeIntervalSince1970: 3_000_000)

        let ok = try CorveilConnectionPersistence.recordRefreshSuccess(
            devRoot: devRoot, tokens: CorveilOAuthTokens(accessToken: "new-at"), now: now)
        #expect(ok)
        let health = try #require(storedHealth(devRoot))
        #expect(health.lastRefreshAt == now)
        #expect(health.lastRefreshError == nil)
        #expect(!health.needsReconnect)
    }

    @Test func recordRefreshFailureLatchesReconnectOnlyWhenAsked() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try seed(devRoot: devRoot, expiresAt: Date())

        // A transient failure records the message but does not latch reconnect.
        #expect(try CorveilConnectionPersistence.recordRefreshFailure(
            devRoot: devRoot, error: "network down", needsReconnect: false))
        var health = try #require(storedHealth(devRoot))
        #expect(health.lastRefreshError == "network down")
        #expect(!health.needsReconnect)

        // A definitive rejection latches it.
        #expect(try CorveilConnectionPersistence.recordRefreshFailure(
            devRoot: devRoot, error: "invalid_grant", needsReconnect: true))
        health = try #require(storedHealth(devRoot))
        #expect(health.needsReconnect)

        // A later transient failure must not *clear* the latch.
        #expect(try CorveilConnectionPersistence.recordRefreshFailure(
            devRoot: devRoot, error: "flaky again", needsReconnect: false))
        #expect(try #require(storedHealth(devRoot)).needsReconnect)
    }

    @Test func recordRefreshReturnsFalseWithoutConnection() throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        #expect(try !CorveilConnectionPersistence.recordRefreshSuccess(
            devRoot: devRoot, tokens: CorveilOAuthTokens(accessToken: "x"), now: Date()))
        #expect(try !CorveilConnectionPersistence.recordRefreshFailure(
            devRoot: devRoot, error: "x", needsReconnect: true))
    }

    // MARK: - Watcher (schedule + classify)

    @Test func isDueSchedulesAgainstTheRefreshMargin() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func conn(_ expiresAt: Date?) -> CorveilConnection {
            CorveilConnection(oauth: CorveilOAuthTokens(accessTokenExpiresAt: expiresAt))
        }
        // Unknown expiry is never scheduled.
        #expect(!CorveilTokenRefreshWatcher.isDue(conn(nil), now: now))
        // Comfortably in the future → not due.
        #expect(!CorveilTokenRefreshWatcher.isDue(conn(now.addingTimeInterval(3600)), now: now))
        // Inside the 10-minute window → due.
        #expect(CorveilTokenRefreshWatcher.isDue(conn(now.addingTimeInterval(120)), now: now))
        // Already expired → still due (catch-up).
        #expect(CorveilTokenRefreshWatcher.isDue(conn(now.addingTimeInterval(-60)), now: now))
    }

    @Test func isGrantRejectionOnlyForDeadGrants() {
        typealias F = CorveilOAuthClient.Failure
        #expect(CorveilTokenRefreshWatcher.isGrantRejection(F.oauth(error: "invalid_grant", description: nil)))
        #expect(CorveilTokenRefreshWatcher.isGrantRejection(F.oauth(error: "invalid_client", description: nil)))
        // A server hiccup or a slow-down is transient, not a reason to reconnect.
        #expect(!CorveilTokenRefreshWatcher.isGrantRejection(F.oauth(error: "temporarily_unavailable", description: nil)))
        #expect(!CorveilTokenRefreshWatcher.isGrantRejection(F.http(status: 503, body: "")))
        #expect(!CorveilTokenRefreshWatcher.isGrantRejection(F.transport("connection refused")))
    }

    @Test func watcherRefreshesADueTokenAndStampsHealth() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let now = Date(timeIntervalSince1970: 5_000_000)
        try seed(devRoot: devRoot, expiresAt: now.addingTimeInterval(120))  // within margin

        let client = CorveilOAuthClient(transport: transport { _ in
            (200, self.jsonData([
                "access_token": "new-at", "refresh_token": "new-rt",
                "token_type": "Bearer", "expires_in": 3600, "scope": "orgs.read",
            ]))
        })
        let outcome = await CorveilTokenRefreshWatcher.tick(devRoot: devRoot, client: client, now: now)
        #expect(outcome == .refreshed)

        let connection = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(connection.oauth.accessToken == "new-at")
        #expect(connection.oauth.accessTokenExpiresAt == now.addingTimeInterval(3600))
        #expect(connection.health.lastRefreshAt == now)
        #expect(!connection.health.needsReconnect)
        #expect(connection.healthState(now: now.addingTimeInterval(1)) == .connected)
    }

    @Test func watcherSkipsAFreshToken() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let now = Date(timeIntervalSince1970: 5_000_000)
        try seed(devRoot: devRoot, expiresAt: now.addingTimeInterval(3600))  // far future

        let log = RequestLog()
        let client = CorveilOAuthClient(transport: transport(log: log) { _ in (200, Data()) })
        let outcome = await CorveilTokenRefreshWatcher.tick(devRoot: devRoot, client: client, now: now)
        #expect(outcome == .notDue)
        #expect(log.all.isEmpty)  // never hit the network
        // Token untouched.
        #expect(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection?.oauth.accessToken == "old-at")
    }

    @Test func watcherLatchesReconnectOnInvalidGrant() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let now = Date(timeIntervalSince1970: 5_000_000)
        try seed(devRoot: devRoot, expiresAt: now.addingTimeInterval(-30))  // expired → due

        let client = CorveilOAuthClient(transport: transport { _ in
            (400, self.jsonData(["error": "invalid_grant", "error_description": "token revoked"]))
        })
        let outcome = await CorveilTokenRefreshWatcher.tick(devRoot: devRoot, client: client, now: now)
        #expect(outcome == .failed(needsReconnect: true))

        let connection = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(connection.health.needsReconnect)
        #expect(connection.oauth.accessToken == "old-at")  // stale token left in place
        #expect(connection.healthState(now: now) == .revoked)
    }

    @Test func watcherKeepsRetryingOnTransientError() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        let now = Date(timeIntervalSince1970: 5_000_000)
        try seed(devRoot: devRoot, expiresAt: now.addingTimeInterval(-30))

        let client = CorveilOAuthClient(transport: transport { _ in (503, Data("upstream".utf8)) })
        let outcome = await CorveilTokenRefreshWatcher.tick(devRoot: devRoot, client: client, now: now)
        #expect(outcome == .failed(needsReconnect: false))

        let connection = try #require(ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection)
        #expect(!connection.health.needsReconnect)  // a 5xx is not the user's to fix
        #expect(connection.health.lastRefreshError != nil)
        // Still just "expired" (clock), not "revoked".
        #expect(connection.healthState(now: now) == .expired)
    }

    @Test func watcherNoOpsWithoutAConnectionOrRefreshToken() async throws {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        // Nothing stored.
        #expect(await CorveilTokenRefreshWatcher.tick(devRoot: devRoot) == .noConnection)
        // A connection with no refresh token cannot be refreshed here.
        let now = Date(timeIntervalSince1970: 5_000_000)
        try seed(devRoot: devRoot, expiresAt: now.addingTimeInterval(-30), refreshToken: "")
        #expect(await CorveilTokenRefreshWatcher.tick(devRoot: devRoot, now: now) == .notRefreshable)
    }
}
