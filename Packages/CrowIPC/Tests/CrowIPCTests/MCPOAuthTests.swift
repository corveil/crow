import CrowCore
import Foundation
import Testing

@testable import CrowIPC

/// The pure half of Crow's OAuth authorization server (CROW-1465). Runs in the
/// Linux PR lane; the routes, state and PKCE hash are covered by
/// `MCPOAuthRoutesTests` in `CrowDaemonTests`.
@Suite("MCP OAuth — protocol rules")
struct MCPOAuthTests {

    // MARK: - Transport

    @Test("A loopback peer with no proxy headers is local and allowed")
    func localDirectAllowed() {
        #expect(MCPOAuth.transportProblem(peerIsLoopback: true, forwardedFor: nil, forwardedProto: nil) == nil)
    }

    @Test("A proxied request must have been forwarded as HTTPS")
    func proxiedNeedsHTTPS() {
        #expect(MCPOAuth.transportProblem(
            peerIsLoopback: true, forwardedFor: "100.64.0.9", forwardedProto: "https") == nil)
        #expect(MCPOAuth.transportProblem(
            peerIsLoopback: true, forwardedFor: "100.64.0.9", forwardedProto: "http") != nil)
        #expect(MCPOAuth.transportProblem(
            peerIsLoopback: true, forwardedFor: "100.64.0.9", forwardedProto: nil) != nil)
    }

    @Test("A direct non-loopback peer is refused, whatever headers it sends")
    func directRemoteRefused() {
        #expect(MCPOAuth.transportProblem(peerIsLoopback: false, forwardedFor: nil, forwardedProto: nil) != nil)
        #expect(MCPOAuth.transportProblem(
            peerIsLoopback: false, forwardedFor: "1.2.3.4", forwardedProto: "https") != nil)
    }

    // MARK: - Paths

    @Test("Exactly the OAuth surface is exempt from web auth")
    func oauthPaths() {
        for path in [
            "/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp",
            "/.well-known/oauth-authorization-server", "/oauth/register", "/oauth/authorize", "/oauth/token",
        ] {
            #expect(MCPOAuth.isOAuthPath(path), "\(path)")
        }
        for path in ["/", "/rpc", "/oauth", "/oauth/", "/oauth/tokens", "/.well-known/openid-configuration",
                     "/.well-known/oauth-protected-resource/other", "/config/mcp-tokens"] {
            #expect(!MCPOAuth.isOAuthPath(path), "\(path)")
        }
    }

    // MARK: - Form parsing

    @Test("Form decoding handles + and percent escapes")
    func formDecoding() throws {
        let params = try #require(MCPOAuth.uniqueParameters(MCPOAuth.formPairs(
            "a=hello+world&b=x%2By%26z&redirect_uri=https%3A%2F%2Fclaude.ai%2Fcb&empty=")))
        #expect(params["a"] == "hello world")
        #expect(params["b"] == "x+y&z")
        #expect(params["redirect_uri"] == "https://claude.ai/cb")
        #expect(params["empty"] == "")
    }

    @Test("A repeated parameter makes the request invalid")
    func repeatedParameter() {
        #expect(MCPOAuth.uniqueParameters(MCPOAuth.formPairs("redirect_uri=a&redirect_uri=b")) == nil)
    }

    // MARK: - Scopes

    @Test("An absent scope is unspecified; offline_access is ignored")
    func scopeParsing() throws {
        #expect(try MCPOAuth.parseScope(nil).get().isEmpty)
        #expect(try MCPOAuth.parseScope("").get().isEmpty)
        #expect(try MCPOAuth.parseScope("board:read offline_access").get() == [.boardRead])
        #expect(try MCPOAuth.parseScope("sessions:read  todos:read").get() == [.sessionsRead, .todosRead])
        #expect(try MCPOAuth.parseScope("todos:read todos:write").get() == [.todosRead, .todosWrite])
    }

    @Test("An unknown scope is invalid_scope, not dropped")
    func unknownScope() {
        guard case .failure(let failure) = MCPOAuth.parseScope("board:read sessions:write") else {
            Issue.record("expected a failure"); return
        }
        #expect(failure.code == "invalid_scope")
    }

    // MARK: - PKCE format

    @Test("code_verifier must be 43–128 unreserved characters")
    func verifierFormat() {
        #expect(MCPOAuth.isValidCodeVerifier(String(repeating: "a", count: 43)))
        #expect(MCPOAuth.isValidCodeVerifier(String(repeating: "Z9-._~", count: 21)))
        #expect(!MCPOAuth.isValidCodeVerifier(String(repeating: "a", count: 42)))
        #expect(!MCPOAuth.isValidCodeVerifier(String(repeating: "a", count: 129)))
        #expect(!MCPOAuth.isValidCodeVerifier(String(repeating: "a", count: 42) + "!"))
    }

    @Test("An S256 challenge is exactly 43 base64url characters")
    func challengeFormat() {
        // RFC 7636 Appendix B.
        #expect(MCPOAuth.isValidS256Challenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"))
        #expect(!MCPOAuth.isValidS256Challenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM="))
        #expect(!MCPOAuth.isValidS256Challenge("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw+cM"))
        #expect(!MCPOAuth.isValidS256Challenge("short"))
    }

    // MARK: - Redirect URIs

    @Test("https and loopback http redirect URIs are registrable")
    func acceptableRedirects() {
        #expect(MCPOAuth.redirectURIProblem("https://claude.ai/api/mcp/auth_callback") == nil)
        #expect(MCPOAuth.redirectURIProblem("http://localhost:3118/callback") == nil)
        #expect(MCPOAuth.redirectURIProblem("http://127.0.0.1/callback") == nil)
        #expect(MCPOAuth.redirectURIProblem("http://[::1]:9000/cb") == nil)
    }

    @Test("Other redirect URIs are refused")
    func refusedRedirects() {
        for uri in [
            "http://claude.ai/callback",          // plain http, remote
            "https://claude.ai/cb#frag",          // fragment
            "https://user:pw@claude.ai/cb",       // userinfo
            "myapp://callback",                   // custom scheme
            "javascript:alert(1)",
            "/relative",
            "",
            "https://claude.ai/cb\nx",
        ] {
            #expect(MCPOAuth.redirectURIProblem(uri) != nil, "\(uri)")
        }
    }

    @Test("Redirect matching is exact, except for a loopback port")
    func redirectMatching() {
        let registered = ["https://claude.ai/api/mcp/auth_callback", "http://localhost/callback"]
        #expect(MCPOAuth.redirectURIMatches(registered: registered, presented: "https://claude.ai/api/mcp/auth_callback"))
        #expect(MCPOAuth.redirectURIMatches(registered: registered, presented: "http://localhost:51234/callback"))
        #expect(!MCPOAuth.redirectURIMatches(registered: registered, presented: "https://claude.ai/api/mcp/auth_callback/"))
        #expect(!MCPOAuth.redirectURIMatches(registered: registered, presented: "https://claude.ai:8443/api/mcp/auth_callback"))
        #expect(!MCPOAuth.redirectURIMatches(registered: registered, presented: "http://localhost:51234/other"))
        #expect(!MCPOAuth.redirectURIMatches(registered: registered, presented: "http://127.0.0.1:51234/callback"))
        #expect(!MCPOAuth.redirectURIMatches(registered: registered, presented: "https://evil.example/api/mcp/auth_callback"))
    }

    @Test("The redirect builder keeps an existing query and encodes values")
    func redirectBuilder() {
        #expect(MCPOAuth.redirect("https://a.example/cb", adding: [("code", "abc"), ("state", "x y&z")])
            == "https://a.example/cb?code=abc&state=x%20y%26z")
        #expect(MCPOAuth.redirect("https://a.example/cb?k=v", adding: [("code", "abc")])
            == "https://a.example/cb?k=v&code=abc")
    }

    // MARK: - Registration

    @Test("A Claude-shaped registration is accepted as a public client")
    func claudeRegistration() throws {
        let body: [String: JSONValue] = [
            "client_name": .string("Claude"),
            "redirect_uris": .array([.string("https://claude.ai/api/mcp/auth_callback")]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("client_secret_post"),
        ]
        let registration = try MCPOAuth.validateRegistration(body).get()
        #expect(registration.clientName == "Claude")
        let response = MCPOAuth.registrationResponse(
            clientID: "crow_mcpc_x", registration: registration, issuedAt: Date())
        // Whatever was asked for, the client is public and must use PKCE.
        #expect(response["token_endpoint_auth_method"] == .string("none"))
        #expect(response["client_secret"] == nil)
    }

    @Test("Registration rejects missing or bad redirect URIs and unsupported grants")
    func badRegistrations() {
        func code(_ body: [String: JSONValue]) -> String? {
            if case .failure(let f) = MCPOAuth.validateRegistration(body) { return f.code }
            return nil
        }
        #expect(code([:]) == "invalid_redirect_uri")
        #expect(code(["redirect_uris": .array([])]) == "invalid_redirect_uri")
        #expect(code(["redirect_uris": .array([.string("http://evil.example/cb")])]) == "invalid_redirect_uri")
        #expect(code([
            "redirect_uris": .array([.string("https://ok.example/cb")]),
            "grant_types": .array([.string("implicit")]),
        ]) == "invalid_client_metadata")
        #expect(code([
            "redirect_uris": .array(Array(repeating: .string("https://ok.example/cb"), count: 6)),
        ]) == "invalid_redirect_uri")
    }

    @Test("A missing client name gets a placeholder, and a long one is capped")
    func clientNameDefaults() throws {
        let uris: JSONValue = .array([.string("https://ok.example/cb")])
        #expect(try MCPOAuth.validateRegistration(["redirect_uris": uris]).get().clientName == "Unnamed MCP client")
        let long = String(repeating: "x", count: 500)
        let named = try MCPOAuth.validateRegistration(["redirect_uris": uris, "client_name": .string(long)]).get()
        #expect(named.clientName.count == MCPOAuth.maxClientNameLength)
    }

    // MARK: - Authorization request

    private let client = MCPOAuth.Client(
        clientID: "crow_mcpc_abc", clientName: "Claude",
        redirectURIs: ["https://claude.ai/api/mcp/auth_callback"])
    private let resource = "https://crow.example.ts.net/mcp"
    private let challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    private func authorize(_ overrides: [String: String?]) -> MCPOAuth.AuthorizeOutcome {
        var params: [String: String] = [
            "client_id": client.clientID,
            "redirect_uri": client.redirectURIs[0],
            "response_type": "code",
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": "st",
            "resource": resource,
        ]
        for (key, value) in overrides { params[key] = value }
        return MCPOAuth.validateAuthorization(params, resource: resource) { [client] id in
            id == client.clientID ? client : nil
        }
    }

    @Test("A well-formed request is valid and records what was asked")
    func validAuthorization() throws {
        guard case .valid(let request) = authorize(["scope": "board:read"]) else {
            Issue.record("expected valid"); return
        }
        #expect(request.requestedScopes == [.boardRead])
        #expect(request.offeredScopes == [.boardRead])
        #expect(request.resource == resource)
        #expect(request.state == "st")
    }

    @Test("No scope offers every scope at consent")
    func noScopeOffersAll() {
        guard case .valid(let request) = authorize([:]) else { Issue.record("expected valid"); return }
        #expect(request.offeredScopes == MCPScope.all)
    }

    @Test("An unknown client or unregistered redirect URI is shown, never redirected")
    func untrustedRedirectNeverFollowed() {
        if case .showError = authorize(["client_id": "nope"]) {} else { Issue.record("unknown client") }
        if case .showError = authorize(["redirect_uri": "https://evil.example/cb"]) {} else {
            Issue.record("unregistered redirect must not be redirected to")
        }
        if case .showError = authorize(["redirect_uri": nil]) {} else { Issue.record("missing redirect") }
        if case .showError = MCPOAuth.validateAuthorization(nil, resource: resource, client: { _ in nil }) {} else {
            Issue.record("duplicate params")
        }
    }

    @Test("PKCE is mandatory and only S256 is accepted")
    func pkceRequired() {
        func errorCode(_ outcome: MCPOAuth.AuthorizeOutcome) -> String? {
            if case .redirectError(_, let failure, _) = outcome { return failure.code }
            return nil
        }
        #expect(errorCode(authorize(["code_challenge": nil])) == "invalid_request")
        #expect(errorCode(authorize(["code_challenge_method": nil])) == "invalid_request")  // defaults to plain
        #expect(errorCode(authorize(["code_challenge_method": "plain"])) == "invalid_request")
        #expect(errorCode(authorize(["code_challenge": "too-short"])) == "invalid_request")
    }

    @Test("Other request errors go back to the registered redirect")
    func redirectedErrors() {
        func errorCode(_ outcome: MCPOAuth.AuthorizeOutcome) -> String? {
            if case .redirectError(let uri, let failure, let state) = outcome {
                #expect(uri == client.redirectURIs[0])
                #expect(state == "st")
                return failure.code
            }
            return nil
        }
        #expect(errorCode(authorize(["response_type": "token"])) == "unsupported_response_type")
        #expect(errorCode(authorize(["scope": "admin"])) == "invalid_scope")
        #expect(errorCode(authorize(["resource": "https://other.example/mcp"])) == "invalid_target")
    }

    @Test("resource tolerates a trailing slash and may be omitted")
    func resourceMatching() {
        if case .valid = authorize(["resource": resource + "/"]) {} else { Issue.record("trailing slash") }
        if case .valid = authorize(["resource": nil]) {} else { Issue.record("omitted") }
    }

    @Test("Authorization responses carry iss (RFC 9207)")
    func responseParams() {
        let params = MCPOAuth.authorizationResponse(code: "c", state: "s", issuer: "https://h")
        #expect(params.map(\.0) == ["code", "state", "iss"])
        let error = MCPOAuth.errorResponse(.init("access_denied", "no"), state: nil, issuer: "https://h")
        #expect(error.map(\.0) == ["error", "error_description", "iss"])
    }

    // MARK: - Token request helpers

    @Test("client_id comes from the body, or from a Basic header's username")
    func tokenClientID() {
        #expect(MCPOAuth.tokenClientID(form: ["client_id": "a"], authorization: nil) == "a")
        let basic = "Basic " + Data("crow_mcpc_b:ignored".utf8).base64EncodedString()
        #expect(MCPOAuth.tokenClientID(form: [:], authorization: basic) == "crow_mcpc_b")
        #expect(MCPOAuth.tokenClientID(form: [:], authorization: nil) == nil)
        #expect(MCPOAuth.tokenClientID(form: [:], authorization: "Bearer x") == nil)
    }

    @Test("Token responses are Bearer with an hour's expiry")
    func tokenResponseShape() {
        let response = MCPOAuth.tokenResponse(accessToken: "a", refreshToken: "r", scopes: [MCPScope.boardRead])
        #expect(response["token_type"] == .string("Bearer"))
        #expect(response["expires_in"] == .int(3600))
        #expect(response["scope"] == .string("board:read"))
    }

    // MARK: - Public origin and metadata

    @Test("Forwarded host and proto are honoured from a loopback proxy")
    func forwardedOrigin() throws {
        let origin = try #require(MCPOAuthOrigin.derive(
            hostHeader: "127.0.0.1:8787", forwardedHost: "crow.example.ts.net",
            forwardedProto: "https", peerIsLoopback: true))
        #expect(origin.origin == "https://crow.example.ts.net")
        #expect(origin.resource == "https://crow.example.ts.net/mcp")
        #expect(origin.protectedResourceMetadataURL
            == "https://crow.example.ts.net/.well-known/oauth-protected-resource/mcp")
    }

    @Test("Forwarded headers from a non-loopback peer are ignored")
    func forwardedFromRemoteIgnored() throws {
        let origin = try #require(MCPOAuthOrigin.derive(
            hostHeader: "192.168.1.5:8787", forwardedHost: "evil.example",
            forwardedProto: "https", peerIsLoopback: false))
        #expect(origin.origin == "http://192.168.1.5:8787")
    }

    @Test("A Funnel on a non-default port keeps it; a default port is dropped")
    func ports() throws {
        let funnel = try #require(MCPOAuthOrigin.derive(
            hostHeader: nil, forwardedHost: "crow.example.ts.net:8443", forwardedProto: "https",
            peerIsLoopback: true))
        #expect(funnel.origin == "https://crow.example.ts.net:8443")
        let standard = try #require(MCPOAuthOrigin.derive(
            hostHeader: nil, forwardedHost: "crow.example.ts.net:443", forwardedProto: "https",
            peerIsLoopback: true))
        #expect(standard.origin == "https://crow.example.ts.net")
    }

    @Test("A host that could smuggle a quote or path is refused")
    func hostInjection() {
        for host in [#"evil.example", resource_metadata="x"#, "a.example/path", "a@b.example", ""] {
            #expect(MCPOAuthOrigin.derive(
                hostHeader: host, forwardedHost: nil, forwardedProto: nil, peerIsLoopback: true) == nil, "\(host)")
        }
    }

    @Test("The 401 challenge points at the protected-resource metadata")
    func bearerChallenge() throws {
        let origin = try #require(MCPOAuthOrigin(scheme: "https", host: "crow.example.ts.net"))
        #expect(origin.bearerChallenge
            == #"Bearer realm="crow-mcp", resource_metadata="https://crow.example.ts.net/.well-known/oauth-protected-resource/mcp""#)
    }

    @Test("Metadata documents name the public origin and the S256-only, public-client profile")
    func metadataDocuments() throws {
        let origin = try #require(MCPOAuthOrigin(scheme: "https", host: "crow.example.ts.net"))
        let resource = origin.protectedResourceMetadata
        #expect(resource["resource"] == .string("https://crow.example.ts.net/mcp"))
        #expect(resource["authorization_servers"] == .array([.string("https://crow.example.ts.net")]))
        #expect(resource["scopes_supported"]?.arrayValue?.count == MCPScope.allCases.count)
        #expect(resource["scopes_supported"]?.arrayValue?.contains(.string("todos:write")) == true)

        let server = origin.authorizationServerMetadata
        #expect(server["issuer"] == .string("https://crow.example.ts.net"))
        #expect(server["authorization_endpoint"] == .string("https://crow.example.ts.net/oauth/authorize"))
        #expect(server["token_endpoint"] == .string("https://crow.example.ts.net/oauth/token"))
        #expect(server["registration_endpoint"] == .string("https://crow.example.ts.net/oauth/register"))
        #expect(server["code_challenge_methods_supported"] == .array([.string("S256")]))
        #expect(server["token_endpoint_auth_methods_supported"] == .array([.string("none")]))
        // Not advertised: a refresh token is always issued (see the MCP spec's note
        // on offline_access), and Claude appends it only when this lists it.
        #expect(server["scopes_supported"]?.arrayValue?.contains(.string("offline_access")) == false)
    }

    // MARK: - Consent page

    @Test("Client-chosen text is escaped on the consent page")
    func consentEscaping() {
        let hostile = MCPOAuth.Client(
            clientID: "c", clientName: #"<script>alert("x")</script>"#,
            redirectURIs: ["https://claude.ai/cb?a=<b>"])
        let request = MCPOAuth.AuthorizationRequest(
            client: hostile, redirectURI: hostile.redirectURIs[0], state: nil, codeChallenge: challenge,
            requestedScopes: [], resource: resource)
        let html = MCPOAuthConsentPage.consent(request: request, consentID: #"id"><x"#)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains(#"id"><x"#))
        #expect(html.contains("claude.ai"))
        #expect(html.contains(#"type="password""#))
        #expect(html.contains("<script") == false)
    }

    @Test("The consent page pre-ticks the requested scopes only")
    func consentTicks() {
        let request = MCPOAuth.AuthorizationRequest(
            client: client, redirectURI: client.redirectURIs[0], state: nil, codeChallenge: challenge,
            requestedScopes: [.boardRead], resource: resource)
        let html = MCPOAuthConsentPage.consent(request: request, consentID: "x")
        #expect(html.contains(#"value="board:read" checked"#))
        #expect(!html.contains(#"value="sessions:read" checked"#))
    }

    @Test("A write scope is never pre-ticked, even when the client asks for it")
    func consentNeverPreTicksWrites() {
        for requested: Set<MCPScope> in [[], [.todosRead, .todosWrite], MCPScope.all] {
            let request = MCPOAuth.AuthorizationRequest(
                client: client, redirectURI: client.redirectURIs[0], state: nil, codeChallenge: challenge,
                requestedScopes: requested, resource: resource)
            let html = MCPOAuthConsentPage.consent(request: request, consentID: "x")
            #expect(html.contains(#"value="todos:write">"#), "todos:write is offered unticked")
            #expect(!html.contains(#"value="todos:write" checked"#))
            #expect(html.contains(#"value="todos:read" checked"#))
            // The page lists a write scope, so it must not promise read-only.
            #expect(!html.contains("read-only"))
            #expect(html.contains("Allow it to change"))
        }
    }

    @Test("A write scope the operator ticked stays ticked when the form is re-shown")
    func consentKeepsOperatorTicks() {
        let request = MCPOAuth.AuthorizationRequest(
            client: client, redirectURI: client.redirectURIs[0], state: nil, codeChallenge: challenge,
            requestedScopes: [], resource: resource)
        let html = MCPOAuthConsentPage.consent(
            request: request, consentID: "x", checked: [.todosWrite], message: "wrong password")
        #expect(html.contains(#"value="todos:write" checked"#))
        #expect(!html.contains(#"value="todos:read" checked"#))
    }

    @Test("With no web password the page refuses and has no form")
    func passwordRequiredPage() {
        let html = MCPOAuthConsentPage.passwordRequired()
        #expect(html.contains("Set a web password first"))
        #expect(!html.contains("<form"))
        #expect(html.contains("<code>crow web-password set</code>"))
    }

    // MARK: - Grant wire form

    @Test("A grant's public JSON never carries the refresh-token hash")
    func grantRedaction() {
        let grant = MCPOAuthGrant(
            clientID: "c", clientName: "Claude", redirectURIs: ["https://claude.ai/cb"],
            scopes: [.boardRead], resource: resource, refreshTokenHashB64: "c2VjcmV0",
            refreshExpiresAt: Date().addingTimeInterval(60))
        let json = grant.publicJSON(activeAccessTokens: 1)
        #expect(!String(describing: json).contains("c2VjcmV0"))
        #expect(json["client_name"] == .string("Claude"))
        #expect(json["kind"] == .string("oauth"))
        #expect(json["active_access_tokens"] == .int(1))
    }
}
