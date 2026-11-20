import CrowCore
import Foundation

/// Crow as an OAuth 2.1 authorization server for its own MCP endpoint (CROW-1465).
///
/// Claude's connectors (claude.ai, Claude Desktop, the mobile apps) call `/mcp`
/// from Anthropic's cloud and can only authenticate with OAuth, as the MCP
/// authorization spec describes it: protected-resource metadata (RFC 9728),
/// authorization-server metadata (RFC 8414), dynamic client registration
/// (RFC 7591), and the authorization-code grant with PKCE `S256` (RFC 7636).
/// They cannot send a fixed `Authorization: Bearer crow_mcp_…` header, so before
/// this a minted token could not serve them.
///
/// This file holds the **pure** half — URL derivation, metadata documents,
/// request validation, form parsing and the consent page markup — so it runs in
/// the Linux PR lane. The state (pending registrations, codes, grants), the
/// SHA-256 and the Hummingbird routes are in `CrowDaemon` (`MCPOAuthRoutes`).
///
/// ### The one gate
///
/// Once `/mcp` and these endpoints are public, the consent step is the only thing
/// between a stranger and a token. Web auth is opt-in — with no web password set,
/// `WebAuthGuard` lets everything through — so consent does **not** lean on it.
/// The consent page always asks for the web password, from loopback too, and with
/// no password configured it refuses and issues nothing.
public enum MCPOAuth {

    // MARK: - Lifetimes and bounds

    /// Access tokens are ordinary `MCPTokenRecord`s that expire after an hour.
    /// Claude refreshes on a 401 and shortly before expiry, so this costs a
    /// connected client nothing and bounds what a leaked access token buys.
    public static let accessTokenLifetime: TimeInterval = 3600
    /// A refresh token lapses 30 days after it was issued. Rotation issues a new
    /// one, so a client in use stays connected and an abandoned grant lapses.
    public static let refreshTokenLifetime: TimeInterval = 30 * 24 * 3600
    /// Authorization codes are single-use and short-lived (RFC 6749 §4.1.2 asks for
    /// at most ten minutes).
    public static let authorizationCodeLifetime: TimeInterval = 300
    /// How long a consent page stays submittable.
    public static let consentLifetime: TimeInterval = 600
    /// How long an unapproved dynamic registration is remembered (in memory only).
    public static let pendingClientLifetime: TimeInterval = 24 * 3600
    /// Most unapproved registrations held at once. Registration is
    /// unauthenticated, so this is a memory bound, not a quota.
    public static let maxPendingClients = 100
    /// Most consent pages open at once.
    public static let maxPendingConsents = 200
    /// Most grants persisted at once. Every grant is an operator approval, so this
    /// is only a backstop against a config that grows without bound.
    public static let maxGrants = 50
    public static let maxRedirectURIs = 5
    public static let maxRedirectURILength = 2048
    public static let maxClientNameLength = 100
    /// Largest request body any OAuth endpoint reads.
    public static let maxBodyBytes = 16 * 1024

    /// Prefixes, so a leaked secret is greppable and says what it is.
    public static let refreshTokenPrefix = "crow_mcprt_"
    public static let clientIDPrefix = "crow_mcpc_"

    // MARK: - Paths

    public static let mcpPath = "/mcp"
    public static let protectedResourceMetadataPath = "/.well-known/oauth-protected-resource"
    public static let authorizationServerMetadataPath = "/.well-known/oauth-authorization-server"
    public static let registerPath = "/oauth/register"
    public static let authorizePath = "/oauth/authorize"
    public static let tokenPath = "/oauth/token"

    /// The protected-resource metadata is served at the root well-known path and
    /// at the path-inserted form for `/mcp` (RFC 9728 §3.1), which is the one
    /// Claude probes first when a 401 carries no pointer.
    public static var protectedResourceMetadataPaths: [String] {
        [protectedResourceMetadataPath, protectedResourceMetadataPath + mcpPath]
    }

    /// Every path the OAuth surface serves. All of them are exempt from
    /// `WebAuthMiddleware` and do their own auth, like `/mcp`: the metadata is
    /// public by design, registration and the token endpoint authenticate with the
    /// OAuth protocol itself, and the consent page asks for the web password.
    public static func isOAuthPath(_ path: String) -> Bool {
        protectedResourceMetadataPaths.contains(path)
            || path == authorizationServerMetadataPath
            || path == registerPath || path == authorizePath || path == tokenPath
    }

    // MARK: - Errors

    /// An OAuth error (RFC 6749 §5.2 / RFC 7591 §3.2.2), as `{error,
    /// error_description}`.
    public struct Failure: Error, LocalizedError, Equatable, Sendable {
        public let code: String
        public let description: String
        public init(_ code: String, _ description: String) {
            self.code = code
            self.description = description
        }

        public var errorDescription: String? { description }

        public var json: [String: JSONValue] {
            ["error": .string(code), "error_description": .string(description)]
        }
    }

    // MARK: - Transport

    /// Why a request must not reach the consent or token endpoints over this
    /// transport, or `nil` when it may.
    ///
    /// Mirrors `WebAuthGuard`: a loopback peer with no `X-Forwarded-For` is local
    /// and fine; a loopback peer *with* one is a co-located proxy and must have
    /// forwarded HTTPS; any other peer reached `crowd` directly, so the web
    /// password and refresh tokens would cross the network in clear. Forwarded
    /// headers are trusted only from a loopback peer, which a remote client cannot
    /// forge.
    public static func transportProblem(
        peerIsLoopback: Bool,
        forwardedFor: String?,
        forwardedProto: String?
    ) -> String? {
        let proxied = !(forwardedFor?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        if peerIsLoopback && !proxied { return nil }
        guard peerIsLoopback else {
            return "Crow's OAuth endpoints are reachable only through an HTTPS proxy "
                + "(Tailscale Funnel or serve, or a tunnel) in front of a loopback-bound crowd."
        }
        guard firstListValue(forwardedProto)?.lowercased() == "https" else {
            return "The proxy in front of crowd must forward HTTPS (X-Forwarded-Proto: https)."
        }
        return nil
    }

    // MARK: - Form and query parsing

    /// Parse `application/x-www-form-urlencoded` (also used for query strings)
    /// into ordered pairs. `+` is a space; malformed percent-escapes keep the raw
    /// text rather than dropping the pair.
    public static func formPairs(_ text: String) -> [(String, String)] {
        text.split(separator: "&", omittingEmptySubsequences: true).compactMap { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first, !rawKey.isEmpty else { return nil }
            let rawValue = kv.count > 1 ? kv[1] : ""
            return (decodeFormComponent(rawKey), decodeFormComponent(rawValue))
        }
    }

    /// The pairs as a dictionary, or `nil` when a parameter repeats. RFC 6749 §3.1
    /// says request parameters MUST NOT be included more than once, and a repeated
    /// `redirect_uri` is exactly where a parser that took "the first one" and a
    /// check that took "the last one" would disagree.
    public static func uniqueParameters(_ pairs: [(String, String)]) -> [String: String]? {
        var result: [String: String] = [:]
        for (key, value) in pairs {
            guard result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    private static func decodeFormComponent(_ raw: Substring) -> String {
        let spaced = raw.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Percent-encode for a query value: everything but RFC 3986 unreserved.
    public static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func firstListValue(_ header: String?) -> String? {
        guard let header else { return nil }
        let first = header.split(separator: ",", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? nil : first
    }

    // MARK: - Scopes

    /// Parse an OAuth `scope` parameter. Empty or absent means "unspecified" —
    /// the consent page then offers every scope.
    ///
    /// `offline_access` is accepted and ignored: Crow always issues a refresh
    /// token, and some clients add it by habit. Anything else unknown is an
    /// `invalid_scope` rather than silently dropped, for the same reason
    /// `MCPScope.parse` refuses to default: a grant narrower than asked for is
    /// discovered when a tool goes missing.
    public static func parseScope(_ raw: String?) -> Result<Set<MCPScope>, Failure> {
        var scopes: Set<MCPScope> = []
        for entry in (raw ?? "").split(separator: " ", omittingEmptySubsequences: true) {
            let name = String(entry)
            if name == "offline_access" { continue }
            guard let scope = MCPScope.parse(name) else {
                return .failure(Failure(
                    "invalid_scope",
                    "unknown scope '\(name)'; Crow's scopes are "
                        + MCPScope.allCases.map(\.rawValue).sorted().joined(separator: " ")))
            }
            scopes.insert(scope)
        }
        return .success(scopes)
    }

    public static func scopeString(_ scopes: some Collection<MCPScope>) -> String {
        scopes.sorted().map(\.rawValue).joined(separator: " ")
    }

    // MARK: - PKCE (RFC 7636)

    /// A `code_verifier` is 43–128 characters of `[A-Za-z0-9-._~]` (§4.1).
    public static func isValidCodeVerifier(_ verifier: String) -> Bool {
        (43...128).contains(verifier.count) && verifier.unicodeScalars.allSatisfy(isUnreserved)
    }

    /// An `S256` challenge is the unpadded base64url of a SHA-256: exactly 43
    /// characters of the base64url alphabet.
    public static func isValidS256Challenge(_ challenge: String) -> Bool {
        challenge.count == 43 && challenge.unicodeScalars.allSatisfy { scalar in
            isBase64URL(scalar)
        }
    }

    private static func isUnreserved(_ scalar: Unicode.Scalar) -> Bool {
        isBase64URL(scalar) || scalar == "." || scalar == "~"
    }

    private static func isBase64URL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
        default: return false
        }
    }

    // MARK: - Redirect URIs

    static let loopbackRedirectHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]

    /// Why `uri` cannot be registered as a redirect URI, or `nil` when it can.
    ///
    /// `https` with a host, or `http` to a loopback host (RFC 8252 §7.3, for
    /// native clients like Claude Code). No fragment (RFC 6749 §3.1.2), no
    /// userinfo, and no other scheme — a custom app scheme can be claimed by any
    /// app on a phone, and a plain-http remote host would carry the code in clear.
    public static func redirectURIProblem(_ uri: String) -> String? {
        guard !uri.isEmpty else { return "redirect URIs must not be empty" }
        guard uri.count <= maxRedirectURILength else {
            return "redirect URIs must be at most \(maxRedirectURILength) characters"
        }
        guard !uri.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
            || CharacterSet.controlCharacters.contains($0) })
        else { return "redirect URIs must not contain whitespace or control characters" }
        guard let components = URLComponents(string: uri),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return "'\(uri)' is not an absolute URL" }
        guard components.fragment == nil else { return "redirect URIs must not have a fragment" }
        guard components.user == nil, components.password == nil else {
            return "redirect URIs must not carry credentials"
        }
        switch scheme {
        case "https":
            return nil
        case "http" where isLoopbackHost(host):
            return nil
        default:
            return "redirect URIs must be https, or http to localhost / 127.0.0.1 / [::1]"
        }
    }

    /// Whether `presented` is one of `registered`. Exact string comparison
    /// (OAuth 2.1 §2.3.1), except that a loopback `http` redirect matches with any
    /// port, as RFC 8252 §7.3 requires: a native client picks an ephemeral port at
    /// authorization time.
    public static func redirectURIMatches(registered: [String], presented: String) -> Bool {
        if registered.contains(presented) { return true }
        guard let candidate = URLComponents(string: presented),
              candidate.scheme?.lowercased() == "http",
              let host = candidate.host?.lowercased(), isLoopbackHost(host)
        else { return false }
        return registered.contains { entry in
            guard let known = URLComponents(string: entry),
                  known.scheme?.lowercased() == "http",
                  known.host?.lowercased() == host
            else { return false }
            return known.percentEncodedPath == candidate.percentEncodedPath
                && known.percentEncodedQuery == candidate.percentEncodedQuery
        }
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        loopbackRedirectHosts.contains(host)
    }

    /// `base` with `params` appended to its query, for the authorization
    /// response. An existing query is kept (RFC 6749 §3.1.2).
    public static func redirect(_ base: String, adding params: [(String, String)]) -> String {
        let encoded = params.map { "\(formEncode($0.0))=\(formEncode($0.1))" }.joined(separator: "&")
        guard !encoded.isEmpty else { return base }
        return base + (base.contains("?") ? "&" : "?") + encoded
    }

    /// The origin (`scheme://host[:port]`) of a redirect URI, for the consent
    /// page's `form-action` CSP: browsers apply it to the redirect after the POST.
    public static func origin(of uri: String) -> String? {
        guard let components = URLComponents(string: uri),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased()
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(bracketed)\(port)"
    }

    // MARK: - Dynamic client registration (RFC 7591)

    /// A validated registration request.
    public struct Registration: Equatable, Sendable {
        public let clientName: String
        public let redirectURIs: [String]
        public init(clientName: String, redirectURIs: [String]) {
            self.clientName = clientName
            self.redirectURIs = redirectURIs
        }
    }

    /// Validate a registration request body.
    ///
    /// Every client is registered as a **public** client (`token_endpoint_auth_method:
    /// none`, PKCE mandatory) whatever it asked for; RFC 7591 §3.2.1 lets the
    /// server replace requested metadata, and the response says what was granted.
    /// Claude registers as a public client anyway. Grant and response types are
    /// checked rather than replaced, because a client that needs `implicit` will
    /// not work no matter what we answer.
    public static func validateRegistration(_ body: [String: JSONValue]) -> Result<Registration, Failure> {
        guard case .array(let rawURIs)? = body["redirect_uris"], !rawURIs.isEmpty else {
            return .failure(Failure("invalid_redirect_uri", "redirect_uris is required"))
        }
        guard rawURIs.count <= maxRedirectURIs else {
            return .failure(Failure(
                "invalid_redirect_uri", "at most \(maxRedirectURIs) redirect_uris may be registered"))
        }
        var uris: [String] = []
        for raw in rawURIs {
            guard let uri = raw.stringValue else {
                return .failure(Failure("invalid_redirect_uri", "redirect_uris must be strings"))
            }
            if let problem = redirectURIProblem(uri) {
                return .failure(Failure("invalid_redirect_uri", problem))
            }
            if !uris.contains(uri) { uris.append(uri) }
        }

        if let grantTypes = body["grant_types"] {
            guard let list = grantTypes.arrayValue?.compactMap(\.stringValue),
                  list.allSatisfy({ $0 == "authorization_code" || $0 == "refresh_token" })
            else {
                return .failure(Failure(
                    "invalid_client_metadata",
                    "grant_types may contain only authorization_code and refresh_token"))
            }
        }
        if let responseTypes = body["response_types"] {
            guard let list = responseTypes.arrayValue?.compactMap(\.stringValue),
                  list.allSatisfy({ $0 == "code" })
            else {
                return .failure(Failure("invalid_client_metadata", "response_types may contain only code"))
            }
        }

        let name = (body["client_name"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return .failure(Failure("invalid_client_metadata", "client_name must not contain control characters"))
        }
        let clientName = name.isEmpty ? "Unnamed MCP client" : String(name.prefix(maxClientNameLength))
        return .success(Registration(clientName: clientName, redirectURIs: uris))
    }

    /// The registration response (RFC 7591 §3.2.1).
    public static func registrationResponse(
        clientID: String,
        registration: Registration,
        issuedAt: Date
    ) -> [String: JSONValue] {
        [
            "client_id": .string(clientID),
            "client_id_issued_at": .int(Int(issuedAt.timeIntervalSince1970)),
            "client_name": .string(registration.clientName),
            "redirect_uris": .array(registration.redirectURIs.map { .string($0) }),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
            "scope": .string(scopeString(MCPScope.allCases)),
        ]
    }

    // MARK: - Authorization request

    /// A client known to the authorization server: a fresh in-memory registration,
    /// or one already persisted on a grant.
    public struct Client: Equatable, Sendable {
        public let clientID: String
        public let clientName: String
        public let redirectURIs: [String]
        public init(clientID: String, clientName: String, redirectURIs: [String]) {
            self.clientID = clientID
            self.clientName = clientName
            self.redirectURIs = redirectURIs
        }
    }

    /// A validated `/oauth/authorize` request, waiting for the operator.
    public struct AuthorizationRequest: Equatable, Sendable {
        public let client: Client
        public let redirectURI: String
        public let state: String?
        public let codeChallenge: String
        /// What the client asked for. Empty means it named none, and the consent
        /// page offers every scope.
        public let requestedScopes: Set<MCPScope>
        public let resource: String
        public init(
            client: Client, redirectURI: String, state: String?, codeChallenge: String,
            requestedScopes: Set<MCPScope>, resource: String
        ) {
            self.client = client
            self.redirectURI = redirectURI
            self.state = state
            self.codeChallenge = codeChallenge
            self.requestedScopes = requestedScopes
            self.resource = resource
        }

        /// The scopes the client is offering to take. The consent page pre-ticks
        /// the read scopes among these, never a write scope (CROW-1491).
        public var offeredScopes: Set<MCPScope> {
            requestedScopes.isEmpty ? MCPScope.all : requestedScopes
        }
    }

    public enum AuthorizeOutcome: Equatable, Sendable {
        case valid(AuthorizationRequest)
        /// The client or redirect URI cannot be trusted, so the error is shown to
        /// the operator and **never** redirected (RFC 6749 §4.1.2.1) — redirecting
        /// to an unregistered URI is an open redirector.
        case showError(String)
        /// The redirect URI is trusted; the error goes back to the client.
        case redirectError(redirectURI: String, Failure, state: String?)
    }

    /// Validate an authorization request's parameters.
    public static func validateAuthorization(
        _ params: [String: String]?,
        resource expectedResource: String,
        client lookup: (String) -> Client?
    ) -> AuthorizeOutcome {
        guard let params else {
            return .showError("A request parameter was repeated. Start the connection again from the app.")
        }
        guard let clientID = params["client_id"], !clientID.isEmpty else {
            return .showError("The request is missing client_id.")
        }
        guard let client = lookup(clientID) else {
            return .showError(
                "This app is not registered with Crow, or its registration expired "
                    + "(for example, because crowd restarted). Start the connection again from the app.")
        }
        guard let redirectURI = params["redirect_uri"], !redirectURI.isEmpty else {
            return .showError("The request is missing redirect_uri.")
        }
        guard redirectURIMatches(registered: client.redirectURIs, presented: redirectURI) else {
            return .showError("The redirect_uri does not match what this app registered, so Crow will not send it a code.")
        }

        let state = params["state"]
        func fail(_ code: String, _ description: String) -> AuthorizeOutcome {
            .redirectError(redirectURI: redirectURI, Failure(code, description), state: state)
        }

        guard params["response_type"] == "code" else {
            return fail("unsupported_response_type", "only response_type=code is supported")
        }
        guard let challenge = params["code_challenge"], !challenge.isEmpty else {
            return fail("invalid_request", "PKCE is required: send code_challenge with code_challenge_method=S256")
        }
        // An absent method means `plain` (RFC 7636 §4.3), which is refused too.
        guard params["code_challenge_method"] == "S256" else {
            return fail("invalid_request", "only code_challenge_method=S256 is supported")
        }
        guard isValidS256Challenge(challenge) else {
            return fail("invalid_request", "code_challenge is not a valid S256 challenge")
        }

        let scopes: Set<MCPScope>
        switch parseScope(params["scope"]) {
        case .failure(let failure): return .redirectError(redirectURI: redirectURI, failure, state: state)
        case .success(let parsed): scopes = parsed
        }

        if let resource = params["resource"], !resourceMatches(resource, expected: expectedResource) {
            return fail("invalid_target", "this server's resource is \(expectedResource)")
        }

        return .valid(AuthorizationRequest(
            client: client, redirectURI: redirectURI, state: state, codeChallenge: challenge,
            requestedScopes: scopes, resource: expectedResource))
    }

    /// Whether a client's `resource` parameter names this server. A trailing
    /// slash is tolerated; anything else must match exactly.
    public static func resourceMatches(_ presented: String, expected: String) -> Bool {
        func trimmed(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        return trimmed(presented) == trimmed(expected)
    }

    /// Parameters for a successful authorization response. `iss` is RFC 9207's
    /// mix-up defence, advertised in the server metadata.
    public static func authorizationResponse(code: String, state: String?, issuer: String) -> [(String, String)] {
        var params = [("code", code)]
        if let state { params.append(("state", state)) }
        params.append(("iss", issuer))
        return params
    }

    public static func errorResponse(_ failure: Failure, state: String?, issuer: String) -> [(String, String)] {
        var params = [("error", failure.code), ("error_description", failure.description)]
        if let state { params.append(("state", state)) }
        params.append(("iss", issuer))
        return params
    }

    // MARK: - Token endpoint

    /// `client_id` for a token request: the body parameter, or the username of an
    /// HTTP Basic header for a client that authenticates that way out of habit.
    /// Every client is public, so a Basic password is ignored.
    public static func tokenClientID(form: [String: String], authorization: String?) -> String? {
        if let id = form["client_id"], !id.isEmpty { return id }
        guard let authorization else { return nil }
        let trimmed = authorization.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("basic "),
              let data = Data(base64Encoded: String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
              let decoded = String(data: data, encoding: .utf8),
              let user = decoded.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first
        else { return nil }
        let id = (String(user).removingPercentEncoding ?? String(user))
        return id.isEmpty ? nil : id
    }

    /// The token response (RFC 6749 §5.1).
    public static func tokenResponse(
        accessToken: String,
        refreshToken: String,
        scopes: some Collection<MCPScope>
    ) -> [String: JSONValue] {
        [
            "access_token": .string(accessToken),
            "token_type": .string("Bearer"),
            "expires_in": .int(Int(accessTokenLifetime)),
            "refresh_token": .string(refreshToken),
            "scope": .string(scopeString(scopes)),
        ]
    }
}

// MARK: - Public origin and metadata

/// The origin a client reached Crow at, which every URL in the metadata names.
///
/// Behind `tailscale serve` / Funnel or a tunnel, the daemon sees a loopback peer
/// and a `Host` of `127.0.0.1:8787`; the public name is in `X-Forwarded-Host` and
/// `X-Forwarded-Proto`. Those are trusted only from a loopback peer — the
/// assumption `WebAuthGuard` and `WebSocketOriginGuard` already make — so a direct
/// client cannot make the metadata name a host of its choosing.
public struct MCPOAuthOrigin: Equatable, Sendable {
    public let scheme: String
    /// Host, with the port when it is not the default.
    public let host: String

    public init?(scheme: String, host: String) {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        guard scheme == "http" || scheme == "https", Self.isPlausibleHost(host) else { return nil }
        self.scheme = scheme
        self.host = host
    }

    public static func derive(
        hostHeader: String?,
        forwardedHost: String?,
        forwardedProto: String?,
        peerIsLoopback: Bool
    ) -> MCPOAuthOrigin? {
        if peerIsLoopback, let forwarded = MCPOAuth.firstListValue(forwardedHost) {
            let proto = MCPOAuth.firstListValue(forwardedProto)?.lowercased() ?? "http"
            return MCPOAuthOrigin(scheme: proto, host: Self.strippingDefaultPort(forwarded, scheme: proto))
        }
        guard let host = hostHeader?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        return MCPOAuthOrigin(scheme: "http", host: Self.strippingDefaultPort(host, scheme: "http"))
    }

    public var origin: String { "\(scheme)://\(host)" }
    /// The issuer identifier. It has no path, so its metadata is at the root
    /// well-known URL (RFC 8414 §3.1).
    public var issuer: String { origin }
    /// The canonical URI of the MCP server, which is the `resource` a client must
    /// name (RFC 8707) and the URL an operator types into Claude.
    public var resource: String { origin + MCPOAuth.mcpPath }
    public var protectedResourceMetadataURL: String {
        origin + MCPOAuth.protectedResourceMetadataPath + MCPOAuth.mcpPath
    }

    /// `WWW-Authenticate` for a 401 from `/mcp`: the pointer a client follows to
    /// discover the authorization server (RFC 9728 §5.1).
    public var bearerChallenge: String {
        #"Bearer realm="crow-mcp", resource_metadata=""# + protectedResourceMetadataURL + #"""#
    }

    /// RFC 9728 protected-resource metadata.
    public var protectedResourceMetadata: [String: JSONValue] {
        [
            "resource": .string(resource),
            "authorization_servers": .array([.string(issuer)]),
            "scopes_supported": .array(MCPScope.allCases.sorted().map { .string($0.rawValue) }),
            "bearer_methods_supported": .array([.string("header")]),
            "resource_name": .string("Crow"),
        ]
    }

    /// RFC 8414 authorization-server metadata.
    ///
    /// `client_id_metadata_document_supported` is `false`: accepting a URL as a
    /// `client_id` means the daemon fetching arbitrary URLs on an unauthenticated
    /// request, and dynamic registration covers Claude. `offline_access` is not
    /// listed, because a refresh token is always issued.
    public var authorizationServerMetadata: [String: JSONValue] {
        [
            "issuer": .string(issuer),
            "authorization_endpoint": .string(origin + MCPOAuth.authorizePath),
            "token_endpoint": .string(origin + MCPOAuth.tokenPath),
            "registration_endpoint": .string(origin + MCPOAuth.registerPath),
            "scopes_supported": .array(MCPScope.allCases.sorted().map { .string($0.rawValue) }),
            "response_types_supported": .array([.string("code")]),
            "response_modes_supported": .array([.string("query")]),
            "grant_types_supported": .array([.string("authorization_code"), .string("refresh_token")]),
            "token_endpoint_auth_methods_supported": .array([.string("none")]),
            "code_challenge_methods_supported": .array([.string("S256")]),
            "authorization_response_iss_parameter_supported": .bool(true),
            "client_id_metadata_document_supported": .bool(false),
        ]
    }

    /// Letters, digits, `.`, `-`, `:` and IPv6 brackets only, so a forwarded
    /// header cannot smuggle a path, userinfo or quote into the metadata or the
    /// `WWW-Authenticate` header.
    static func isPlausibleHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 260 else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "0"..."9", ".", "-", ":", "[", "]": return true
            default: return false
            }
        }
    }

    static func strippingDefaultPort(_ host: String, scheme: String) -> String {
        let suffix = scheme.lowercased() == "https" ? ":443" : ":80"
        return host.hasSuffix(suffix) ? String(host.dropLast(suffix.count)) : host
    }
}

// MARK: - Grant wire form

extension MCPOAuthGrant {
    /// Redacted form for `mcp-token-list` — everything needed to identify and
    /// revoke a grant, never the refresh-token hash.
    public func publicJSON(now: Date = Date(), activeAccessTokens: Int = 0) -> [String: JSONValue] {
        let formatter = ISO8601DateFormatter()
        return [
            "id": .string(id.uuidString),
            "kind": .string("oauth"),
            "client_name": .string(clientName),
            "client_id": .string(clientID),
            "redirect_uris": .array(redirectURIs.map { .string($0) }),
            "scopes": .array(scopes.sorted().map { .string($0.rawValue) }),
            "resource": .string(resource),
            "created_at": .string(formatter.string(from: createdAt)),
            "last_refreshed_at": lastRefreshedAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "refresh_expires_at": .string(formatter.string(from: refreshExpiresAt)),
            "expired": .bool(isRefreshExpired(now: now)),
            "active_access_tokens": .int(activeAccessTokens),
        ]
    }
}
