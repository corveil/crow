import CrowCore
import CrowIPC
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

@testable import CrowDaemon

/// Crow's OAuth authorization server for `/mcp` (CROW-1465), end to end over a real
/// loopback server with the real `WebAuthMiddleware` in front — the shape a Claude
/// connector sees through a Tailscale Funnel.
///
/// Requests carry `X-Forwarded-For` / `-Proto: https` / `-Host`, as the proxy adds
/// them, so the metadata names the public origin and the transport check sees a
/// proxied HTTPS request.
@Suite("MCP OAuth endpoints")
struct MCPOAuthRoutesTests {

    static let publicHost = "crow.example.ts.net"
    static let publicOrigin = "https://crow.example.ts.net"
    static let callback = "https://claude.ai/api/mcp/auth_callback"
    static let password = "correct horse battery staple"

    // MARK: - Fixtures

    private func tempDevRoot(webPassword: String? = MCPOAuthRoutesTests.password) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crowd-mcp-oauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var config = AppConfig()
        if let webPassword { config.webAuth = PasswordHash.make(password: webPassword, iterations: 1000) }
        try ConfigStore.saveConfig(config, devRoot: dir)
        return dir
    }

    private func makeApp(devRoot: String, state: MCPOAuthState = MCPOAuthState()) -> some ApplicationProtocol {
        let router = Router(context: CrowHTTPContext.self)
        router.add(middleware: WebAuthMiddleware<CrowHTTPContext>(
            sessions: SessionStore(), devRoot: devRoot, webDir: nil))
        MCPRoutes.mount(
            on: router, commandRouter: stubRouter(), boundHost: "127.0.0.1",
            devRoot: devRoot, serverVersion: "test")
        MCPOAuthRoutes.mount(
            on: router, boundHost: "127.0.0.1", devRoot: devRoot, state: state,
            consentLimiter: LoginRateLimiter(max: 100, window: 60),
            registrationLimiter: LoginRateLimiter(max: 100, window: 60))
        return Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0), serverName: "crowd-test"))
    }

    private func stubRouter() -> CommandRouter {
        CommandRouter(handlers: [
            "list-sessions": { _ in ["sessions": .array([])] },
            "list-sessions-live": { _ in ["sessions": .object([:])] },
            "list-tickets": { _ in ["issues": .array([])] },
            "list-reviews": { _ in ["reviews": .array([])] },
            "get-session": { _ in ["id": .string(UUID().uuidString)] },
        ])
    }

    /// Headers a `tailscale serve` / Funnel proxy adds.
    private func proxied(_ extra: HTTPFields = [:], proto: String = "https") -> HTTPFields {
        var fields = extra
        fields[HTTPField.Name("x-forwarded-for")!] = "160.79.104.10"
        fields[HTTPField.Name("x-forwarded-proto")!] = proto
        fields[HTTPField.Name("x-forwarded-host")!] = Self.publicHost
        return fields
    }

    private func form(_ pairs: [(String, String)]) -> ByteBuffer {
        ByteBuffer(string: pairs.map { "\(MCPOAuth.formEncode($0.0))=\(MCPOAuth.formEncode($0.1))" }
            .joined(separator: "&"))
    }

    private var formHeaders: HTTPFields { proxied([.contentType: "application/x-www-form-urlencoded"]) }

    private func json(_ buffer: ByteBuffer) throws -> [String: JSONValue] {
        try #require(try JSONDecoder().decode(JSONValue.self, from: Data(buffer.readableBytesView)).objectValue)
    }

    private func query(_ location: String?) throws -> [String: String] {
        let raw = try #require(location)
        let components = try #require(URLComponents(string: raw))
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] { result[item.name] = item.value }
        return result
    }

    private func mcpBody(_ method: String) -> ByteBuffer {
        ByteBuffer(string: #"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{}}"#)
    }

    private struct PKCE { let verifier: String; let challenge: String }

    private func makePKCE() -> PKCE {
        let verifier = MCPTokenStore.randomToken()
        return PKCE(verifier: verifier, challenge: CorveilOAuthClient.challenge(for: verifier))
    }

    private func authorizeURI(clientID: String, pkce: PKCE, scope: String? = "board:read",
                              method: String? = "S256", redirect: String = MCPOAuthRoutesTests.callback) -> String {
        var params: [(String, String)] = [
            ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirect),
            ("code_challenge", pkce.challenge), ("state", "xyz"),
            ("resource", Self.publicOrigin + "/mcp"),
        ]
        if let method { params.append(("code_challenge_method", method)) }
        if let scope { params.append(("scope", scope)) }
        return "/oauth/authorize?" + params.map { "\($0.0)=\(MCPOAuth.formEncode($0.1))" }.joined(separator: "&")
    }

    private func consentID(_ html: String) throws -> String {
        let marker = #"name="consent_id" value=""#
        let start = try #require(html.range(of: marker)).upperBound
        let end = try #require(html[start...].firstIndex(of: "\""))
        return String(html[start..<end])
    }

    // MARK: - Steps

    private func register(_ client: some TestClientProtocol) async throws -> String {
        let body = #"{"client_name":"Claude","redirect_uris":["\#(Self.callback)"],"#
            + #""grant_types":["authorization_code","refresh_token"],"response_types":["code"],"#
            + #""token_endpoint_auth_method":"none"}"#
        return try await client.execute(
            uri: "/oauth/register", method: .post, headers: proxied([.contentType: "application/json"]),
            body: ByteBuffer(string: body)
        ) { response in
            #expect(response.status == .created)
            return try #require(try json(response.body)["client_id"]?.stringValue)
        }
    }

    /// Open the consent page and return its id.
    private func openConsent(_ client: some TestClientProtocol, clientID: String, pkce: PKCE,
                             scope: String? = "board:read") async throws -> String {
        try await client.execute(
            uri: authorizeURI(clientID: clientID, pkce: pkce, scope: scope), method: .get, headers: proxied()
        ) { response in
            #expect(response.status == .ok)
            #expect(response.headers[.contentSecurityPolicy]?.contains("frame-ancestors 'none'") == true)
            return try consentID(String(buffer: response.body))
        }
    }

    /// Approve and return the code from the redirect.
    private func approve(_ client: some TestClientProtocol, consentID: String,
                         scopes: [String] = ["board:read"]) async throws -> String {
        var pairs = [("consent_id", consentID), ("password", Self.password), ("decision", "approve")]
        pairs += scopes.map { ("scope", $0) }
        return try await client.execute(
            uri: "/oauth/authorize", method: .post, headers: formHeaders, body: form(pairs)
        ) { response in
            #expect(response.status == .found)
            let location = response.headers[.location]
            #expect(location?.hasPrefix(Self.callback + "?") == true)
            let params = try query(location)
            #expect(params["state"] == "xyz")
            #expect(params["iss"] == Self.publicOrigin)
            return try #require(params["code"])
        }
    }

    private func exchange(_ client: some TestClientProtocol, code: String, clientID: String, pkce: PKCE,
                          expect status: HTTPResponse.Status = .ok) async throws -> [String: JSONValue] {
        try await client.execute(
            uri: "/oauth/token", method: .post, headers: formHeaders,
            body: form([
                ("grant_type", "authorization_code"), ("code", code), ("client_id", clientID),
                ("redirect_uri", Self.callback), ("code_verifier", pkce.verifier),
                ("resource", Self.publicOrigin + "/mcp"),
            ])
        ) { response in
            #expect(response.status == status)
            #expect(response.headers[.cacheControl] == "no-store")
            return try json(response.body)
        }
    }

    private func refresh(_ client: some TestClientProtocol, token: String, clientID: String,
                         scope: String? = nil) async throws -> (HTTPResponse.Status, [String: JSONValue]) {
        var pairs = [("grant_type", "refresh_token"), ("refresh_token", token), ("client_id", clientID)]
        if let scope { pairs.append(("scope", scope)) }
        return try await client.execute(
            uri: "/oauth/token", method: .post, headers: formHeaders, body: form(pairs)
        ) { response in (response.status, try json(response.body)) }
    }

    private func toolNames(_ client: some TestClientProtocol, accessToken: String) async throws -> [String]? {
        try await client.execute(
            uri: "/mcp", method: .post,
            headers: proxied([.contentType: "application/json", .authorization: "Bearer \(accessToken)"]),
            body: mcpBody("tools/list")
        ) { response in
            guard response.status == .ok else { return nil }
            let tools = try json(response.body)["result"]?.objectValue?["tools"]?.arrayValue ?? []
            return tools.compactMap { $0.objectValue?["name"]?.stringValue }.sorted()
        }
    }

    // MARK: - Discovery

    @Test("An unauthenticated POST /mcp is a 401 pointing at the resource metadata")
    func unauthorizedPointsAtMetadata() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            try await client.execute(
                uri: "/mcp", method: .post, headers: proxied([.contentType: "application/json"]),
                body: ByteBuffer(string: "{}")
            ) { response in
                #expect(response.status == .unauthorized)
                let challenge = try #require(response.headers[.wwwAuthenticate])
                #expect(challenge.hasPrefix("Bearer "))
                #expect(challenge.contains(
                    #"resource_metadata="https://crow.example.ts.net/.well-known/oauth-protected-resource/mcp""#))
            }
        }
    }

    @Test("Both metadata documents are served without a session and name the public origin")
    func metadataDocuments() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            for path in ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"] {
                try await client.execute(uri: path, method: .get, headers: proxied()) { response in
                    #expect(response.status == .ok)
                    let doc = try json(response.body)
                    #expect(doc["resource"] == .string(Self.publicOrigin + "/mcp"))
                    #expect(doc["authorization_servers"] == .array([.string(Self.publicOrigin)]))
                }
            }
            try await client.execute(
                uri: "/.well-known/oauth-authorization-server", method: .get, headers: proxied()
            ) { response in
                #expect(response.status == .ok)
                let doc = try json(response.body)
                #expect(doc["issuer"] == .string(Self.publicOrigin))
                #expect(doc["registration_endpoint"] == .string(Self.publicOrigin + "/oauth/register"))
                #expect(doc["code_challenge_methods_supported"] == .array([.string("S256")]))
            }
        }
    }

    // MARK: - The happy path

    @Test("Register, consent, exchange, call tools/list scoped to consent, refresh")
    func fullFlow() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let pkce = makePKCE()
            let consent = try await openConsent(client, clientID: clientID, pkce: pkce, scope: nil)
            let code = try await approve(client, consentID: consent, scopes: ["board:read"])
            let tokens = try await exchange(client, code: code, clientID: clientID, pkce: pkce)
            #expect(tokens["token_type"] == .string("Bearer"))
            #expect(tokens["scope"] == .string("board:read"))
            let access = try #require(tokens["access_token"]?.stringValue)
            let refreshToken = try #require(tokens["refresh_token"]?.stringValue)
            #expect(access.hasPrefix(MCPTokenStore.tokenPrefix))
            #expect(refreshToken.hasPrefix(MCPOAuth.refreshTokenPrefix))

            // Filtered by what the operator ticked, exactly like a minted token.
            #expect(try await toolNames(client, accessToken: access) == ["list_reviews", "list_tickets"])

            // Persisted: one grant, one access token linked to it, hashes only.
            let config = try #require(ConfigStore.loadConfig(devRoot: devRoot))
            #expect(config.mcpOAuthGrants.count == 1)
            #expect(config.mcpOAuthGrants[0].clientName == "Claude")
            #expect(config.mcpOAuthGrants[0].scopes == [.boardRead])
            #expect(config.mcpTokens.filter { $0.grantID == config.mcpOAuthGrants[0].id }.count == 1)
            let onDisk = try String(contentsOfFile: ConfigStore.configURL(devRoot: devRoot).path, encoding: .utf8)
            #expect(!onDisk.contains(access) && !onDisk.contains(refreshToken))

            // Refresh rotates: the new pair works, the old refresh token does not.
            let (status, refreshed) = try await refresh(client, token: refreshToken, clientID: clientID)
            #expect(status == .ok)
            let newAccess = try #require(refreshed["access_token"]?.stringValue)
            let newRefresh = try #require(refreshed["refresh_token"]?.stringValue)
            #expect(newRefresh != refreshToken)
            #expect(try await toolNames(client, accessToken: newAccess) == ["list_reviews", "list_tickets"])
            let (reuse, reuseBody) = try await refresh(client, token: refreshToken, clientID: clientID)
            #expect(reuse == .badRequest)
            #expect(reuseBody["error"] == .string("invalid_grant"))
        }
    }

    @Test("A refresh cannot widen the grant, and another client cannot use it")
    func refreshBounds() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let pkce = makePKCE()
            let consent = try await openConsent(client, clientID: clientID, pkce: pkce)
            let code = try await approve(client, consentID: consent)
            let tokens = try await exchange(client, code: code, clientID: clientID, pkce: pkce)
            let refreshToken = try #require(tokens["refresh_token"]?.stringValue)

            let (widen, widenBody) = try await refresh(
                client, token: refreshToken, clientID: clientID, scope: "board:read sessions:read")
            #expect(widen == .badRequest)
            #expect(widenBody["error"] == .string("invalid_scope"))

            let (other, otherBody) = try await refresh(client, token: refreshToken, clientID: "crow_mcpc_other")
            #expect(other == .badRequest)
            #expect(otherBody["error"] == .string("invalid_grant"))

            // Neither failure consumed the token.
            let (ok, _) = try await refresh(client, token: refreshToken, clientID: clientID)
            #expect(ok == .ok)
        }
    }

    // MARK: - The consent gate

    @Test("With no web password, authorize refuses and issues nothing — from loopback too")
    func noPasswordNoCode() async throws {
        let devRoot = try tempDevRoot(webPassword: nil)
        let state = MCPOAuthState()
        try await makeApp(devRoot: devRoot, state: state).test(.live) { client in
            let clientID = try await register(client)
            let pkce = makePKCE()
            // Loopback-direct (no proxy headers) and proxied alike.
            for headers in [HTTPFields(), proxied()] {
                try await client.execute(
                    uri: authorizeURI(clientID: clientID, pkce: pkce), method: .get, headers: headers
                ) { response in
                    #expect(response.status == .forbidden)
                    #expect(response.headers[.location] == nil)
                    let html = String(buffer: response.body)
                    #expect(html.contains("Set a web password first"))
                    #expect(!html.contains("consent_id"))
                }
            }
            #expect(ConfigStore.loadConfig(devRoot: devRoot)?.mcpOAuthGrants.isEmpty == true)
        }
    }

    @Test("A password removed after the page opened stops the approval")
    func passwordRemovedMidConsent() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let consent = try await openConsent(client, clientID: clientID, pkce: makePKCE())
            var config = try #require(ConfigStore.loadConfig(devRoot: devRoot))
            config.webAuth = nil
            try ConfigStore.saveConfig(config, devRoot: devRoot)
            try await client.execute(
                uri: "/oauth/authorize", method: .post, headers: formHeaders,
                body: form([("consent_id", consent), ("password", Self.password), ("decision", "approve"),
                            ("scope", "board:read")])
            ) { response in
                #expect(response.status == .forbidden)
                #expect(response.headers[.location] == nil)
            }
        }
    }

    @Test("A wrong password re-shows the page and issues no code")
    func wrongPassword() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let consent = try await openConsent(client, clientID: clientID, pkce: makePKCE())
            try await client.execute(
                uri: "/oauth/authorize", method: .post, headers: formHeaders,
                body: form([("consent_id", consent), ("password", "nope"), ("decision", "approve"),
                            ("scope", "board:read")])
            ) { response in
                #expect(response.status == .forbidden)
                #expect(response.headers[.location] == nil)
                #expect(String(buffer: response.body).contains("not the Crow web password"))
            }
        }
    }

    @Test("Deny redirects with access_denied")
    func deny() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let consent = try await openConsent(client, clientID: clientID, pkce: makePKCE())
            try await client.execute(
                uri: "/oauth/authorize", method: .post, headers: formHeaders,
                body: form([("consent_id", consent), ("decision", "deny")])
            ) { response in
                #expect(response.status == .found)
                let params = try query(response.headers[.location])
                #expect(params["error"] == "access_denied")
                #expect(params["code"] == nil)
            }
        }
    }

    @Test("A consent POST from another site is refused")
    func crossSiteConsent() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let consent = try await openConsent(client, clientID: clientID, pkce: makePKCE())
            var headers = formHeaders
            headers[.origin] = "https://evil.example"
            try await client.execute(
                uri: "/oauth/authorize", method: .post, headers: headers,
                body: form([("consent_id", consent), ("password", Self.password), ("decision", "approve"),
                            ("scope", "board:read")])
            ) { response in
                #expect(response.status == .forbidden)
                #expect(response.headers[.location] == nil)
            }
        }
    }

    // MARK: - Authorization request validation

    @Test("A plain or missing PKCE challenge method is refused")
    func pkceMethodRefused() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            for method in ["plain", nil] as [String?] {
                try await client.execute(
                    uri: authorizeURI(clientID: clientID, pkce: makePKCE(), method: method),
                    method: .get, headers: proxied()
                ) { response in
                    #expect(response.status == .found)
                    let params = try query(response.headers[.location])
                    #expect(params["error"] == "invalid_request")
                }
            }
        }
    }

    @Test("An unregistered redirect URI is refused before consent, with no redirect")
    func unregisteredRedirect() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            try await client.execute(
                uri: authorizeURI(clientID: clientID, pkce: makePKCE(), redirect: "https://evil.example/cb"),
                method: .get, headers: proxied()
            ) { response in
                #expect(response.status == .badRequest)
                #expect(response.headers[.location] == nil)
                #expect(!String(buffer: response.body).contains("consent_id"))
            }
        }
    }

    @Test("A proxy that forwards plain http is refused at authorize and token")
    func plainHTTPProxyRefused() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            try await client.execute(
                uri: authorizeURI(clientID: clientID, pkce: makePKCE()), method: .get, headers: proxied(proto: "http")
            ) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(
                uri: "/oauth/token", method: .post,
                headers: proxied([.contentType: "application/x-www-form-urlencoded"], proto: "http"),
                body: form([("grant_type", "refresh_token"), ("refresh_token", "x"), ("client_id", clientID)])
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    // MARK: - Codes

    @Test("A wrong code_verifier is refused")
    func wrongVerifier() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let pkce = makePKCE()
            let consent = try await openConsent(client, clientID: clientID, pkce: pkce)
            let code = try await approve(client, consentID: consent)
            let body = try await exchange(
                client, code: code, clientID: clientID,
                pkce: PKCE(verifier: makePKCE().verifier, challenge: pkce.challenge), expect: .badRequest)
            #expect(body["error"] == .string("invalid_grant"))
            #expect(ConfigStore.loadConfig(devRoot: devRoot)?.mcpOAuthGrants.isEmpty == true)
        }
    }

    @Test("A reused code is refused and revokes the grant it issued")
    func codeReuseRevokes() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let pkce = makePKCE()
            let consent = try await openConsent(client, clientID: clientID, pkce: pkce)
            let code = try await approve(client, consentID: consent)
            let first = try await exchange(client, code: code, clientID: clientID, pkce: pkce)
            let access = try #require(first["access_token"]?.stringValue)
            #expect(try await toolNames(client, accessToken: access) != nil)

            let second = try await exchange(client, code: code, clientID: clientID, pkce: pkce, expect: .badRequest)
            #expect(second["error"] == .string("invalid_grant"))
            #expect(try await toolNames(client, accessToken: access) == nil)
            #expect(ConfigStore.loadConfig(devRoot: devRoot)?.mcpOAuthGrants.isEmpty == true)
        }
    }

    // MARK: - Revocation

    @Test("Revoking a grant kills its access and refresh tokens on the next request")
    func revokeGrant() async throws {
        let devRoot = try tempDevRoot()
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let clientID = try await register(client)
            let pkce = makePKCE()
            let consent = try await openConsent(client, clientID: clientID, pkce: pkce)
            let code = try await approve(client, consentID: consent)
            let tokens = try await exchange(client, code: code, clientID: clientID, pkce: pkce)
            let access = try #require(tokens["access_token"]?.stringValue)
            let refreshToken = try #require(tokens["refresh_token"]?.stringValue)

            // Revoke by name, the way `crow mcp token revoke --name Claude` does.
            let result = try mutateConfig(devRoot: devRoot) { config in
                try MCPTokenRPC.revoke(id: nil, name: "Claude", in: &config)
            }
            #expect(result["kind"] == .string("oauth"))

            #expect(try await toolNames(client, accessToken: access) == nil)
            let (status, body) = try await refresh(client, token: refreshToken, clientID: clientID)
            #expect(status == .badRequest)
            #expect(body["error"] == .string("invalid_grant"))
            let config = try #require(ConfigStore.loadConfig(devRoot: devRoot))
            #expect(config.mcpOAuthGrants.isEmpty)
            #expect(config.mcpTokens.isEmpty)
        }
    }

    @Test("Minted tokens keep working beside OAuth grants")
    func mintedTokensUnchanged() async throws {
        let devRoot = try tempDevRoot()
        let minted = MCPTokenStore.mint(name: "grok-bot", scopes: [.sessionsRead], expiresAt: nil)
        var config = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        config.mcpTokens.append(minted.record)
        try ConfigStore.saveConfig(config, devRoot: devRoot)
        try await makeApp(devRoot: devRoot).test(.live) { client in
            let names = try #require(try await toolNames(client, accessToken: minted.plaintext))
            #expect(names.contains("list_stuck_sessions"))
        }
        let listed = MCPTokenRPC.listJSON(try #require(ConfigStore.loadConfig(devRoot: devRoot)))
        #expect(listed["count"] == .int(1))
        #expect(listed["grant_count"] == .int(0))
    }
}

/// The in-memory state and the persisted grant operations, with an injected clock.
@Suite("MCP OAuth state")
struct MCPOAuthStateTests {

    private let request = MCPOAuth.AuthorizationRequest(
        client: MCPOAuth.Client(clientID: "c", clientName: "Claude", redirectURIs: ["https://claude.ai/cb"]),
        redirectURI: "https://claude.ai/cb", state: nil,
        codeChallenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        requestedScopes: [], resource: "https://crow.example.ts.net/mcp")

    @Test("Codes are single-use, and a second use is reported as a replay")
    func singleUse() {
        let state = MCPOAuthState()
        let code = state.issueCode(for: request, scopes: [.boardRead])
        guard case .valid = state.redeem(code) else { Issue.record("first redeem"); return }
        let grant = UUID()
        state.recordGrant(grant, forCode: code)
        guard case .replayed(let id) = state.redeem(code) else { Issue.record("second redeem"); return }
        #expect(id == grant)
    }

    @Test("Codes expire within minutes")
    func codesExpire() {
        let state = MCPOAuthState()
        let now = Date()
        let code = state.issueCode(for: request, scopes: [.boardRead], now: now)
        guard case .invalid = state.redeem(code, now: now.addingTimeInterval(MCPOAuth.authorizationCodeLifetime + 1))
        else { Issue.record("expired code redeemed"); return }
        #expect(MCPOAuth.authorizationCodeLifetime <= 600)
    }

    @Test("An unknown code is invalid")
    func unknownCode() {
        guard case .invalid = MCPOAuthState().redeem("nope") else { Issue.record("unknown"); return }
    }

    @Test("Unapproved registrations expire and are bounded")
    func registrationsBounded() {
        let state = MCPOAuthState()
        let now = Date()
        let registration = MCPOAuth.Registration(clientName: "x", redirectURIs: ["https://a.example/cb"])
        let first = state.register(registration, now: now)
        for i in 1...MCPOAuth.maxPendingClients {
            _ = state.register(registration, now: now.addingTimeInterval(TimeInterval(i)))
        }
        #expect(state.client(first.clientID, now: now.addingTimeInterval(200)) == nil)  // evicted
        let late = state.register(registration, now: now)
        #expect(state.client(late.clientID, now: now.addingTimeInterval(MCPOAuth.pendingClientLifetime + 1)) == nil)
    }

    @Test("Pruning drops lapsed grants and their tokens, never minted tokens")
    func pruning() {
        var config = AppConfig()
        let now = Date()
        let lapsed = MCPOAuthGrant(
            clientID: "c", clientName: "Old", redirectURIs: [], scopes: [.boardRead], resource: "r",
            refreshTokenHashB64: "h", refreshExpiresAt: now.addingTimeInterval(-1))
        let live = MCPOAuthGrant(
            clientID: "d", clientName: "New", redirectURIs: [], scopes: [.boardRead], resource: "r",
            refreshTokenHashB64: "h2", refreshExpiresAt: now.addingTimeInterval(60))
        config.mcpOAuthGrants = [lapsed, live]
        config.mcpTokens = [
            MCPTokenRecord(name: "Old", prefix: "", hashB64: "a", scopes: [.boardRead],
                           expiresAt: now.addingTimeInterval(60), grantID: lapsed.id),
            MCPTokenRecord(name: "New", prefix: "", hashB64: "b", scopes: [.boardRead],
                           expiresAt: now.addingTimeInterval(-1), grantID: live.id),
            MCPTokenRecord(name: "minted-expired", prefix: "", hashB64: "c", scopes: [.boardRead],
                           expiresAt: now.addingTimeInterval(-1)),
        ]
        MCPOAuthGrants.prune(&config, now: now)
        #expect(config.mcpOAuthGrants.map(\.clientName) == ["New"])
        #expect(config.mcpTokens.map(\.name) == ["minted-expired"])
    }

    @Test("Re-authorizing the same client replaces its grant instead of stacking one")
    func reauthorizationReplaces() throws {
        let devRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("crowd-oauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: devRoot, withIntermediateDirectories: true)
        let first = try MCPOAuthGrants.create(devRoot: devRoot, request: request, scopes: [.boardRead])
        let second = try MCPOAuthGrants.create(devRoot: devRoot, request: request, scopes: [.sessionsRead])
        let config = try #require(ConfigStore.loadConfig(devRoot: devRoot))
        #expect(config.mcpOAuthGrants.map(\.id) == [second.grant.id])
        #expect(!config.mcpTokens.contains { $0.grantID == first.grant.id })
    }

    @Test("An access token id revokes its whole grant")
    func accessTokenIDResolvesToGrant() throws {
        let grant = MCPOAuthGrant(
            clientID: "c", clientName: "Claude", redirectURIs: [], scopes: [.boardRead], resource: "r",
            refreshTokenHashB64: "h", refreshExpiresAt: Date().addingTimeInterval(60))
        let token = MCPTokenRecord(name: "Claude", prefix: "", hashB64: "a", scopes: [.boardRead],
                                   expiresAt: nil, grantID: grant.id)
        let target = try MCPTokenRPC.revocationTarget(
            id: token.id.uuidString, name: nil, tokens: [token], grants: [grant])
        #expect(target == .grant(grant))
    }

    @Test("A name shared by a minted token and a grant is ambiguous")
    func ambiguousName() {
        let grant = MCPOAuthGrant(
            clientID: "c", clientName: "Claude", redirectURIs: [], scopes: [.boardRead], resource: "r",
            refreshTokenHashB64: "h", refreshExpiresAt: Date().addingTimeInterval(60))
        let minted = MCPTokenRecord(name: "claude", prefix: "", hashB64: "a", scopes: [.boardRead], expiresAt: nil)
        #expect(throws: MCPTokenRPC.Invalid.self) {
            try MCPTokenRPC.revocationTarget(id: nil, name: "Claude", tokens: [minted], grants: [grant])
        }
    }
}
