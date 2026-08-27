import Crypto
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLResponse/URLSession live here on Linux
#endif

/// The Corveil OAuth 2.0 client backing the **Connect** flow (CROW-1119).
///
/// Corveil runs its own OAuth Authorization Server — the RFC 7591 Dynamic Client
/// Registration surface at `/mcp/oauth/*` — so Crow talks to Corveil directly and
/// **self-registers**: no manual client provisioning, no WorkOS redirect-URI
/// change (WorkOS is only the human login *inside* the authorize step). This type
/// is the protocol half: it registers a public PKCE client, builds the authorize
/// URL, exchanges the code, and refreshes the access token. It performs **no I/O
/// beyond HTTP** — the loopback callback route, the in-flight-state store, and the
/// config write live in ``CorveilIntegrationRoutes`` / ``CorveilConnectionStore``.
///
/// The four operations are exactly RFC 6749 (§4.1 authorization code, §6 refresh),
/// RFC 7591 (DCR), and RFC 7636 (PKCE S256) as the Corveil backend implements
/// them (`go/internal/handler/oauth_{register,authorize,token}.go`):
///   - **register** — `POST {base}/mcp/oauth/register`, JSON, `token_endpoint_auth_method:"none"`
///     (public client, PKCE-only) with the loopback redirect URI.
///   - **authorize** — `GET {base}/mcp/oauth/authorize?…` opened in the browser.
///   - **token exchange** — `POST {base}/mcp/oauth/token`, form-urlencoded,
///     `grant_type=authorization_code` + `code_verifier`.
///   - **refresh** — the same endpoint with `grant_type=refresh_token`; the server
///     rotates the refresh token, so the response's `refresh_token` replaces ours.
///
/// `transport` is injected so tests drive the whole flow against a stub without a
/// live Corveil — the same pattern as ``VersionUpdateClient`` / ``JiraTransitionClient``.
struct CorveilOAuthClient: Sendable {
    /// Performs one HTTP round-trip. Defaults to `URLSession.shared` in ``live``.
    var transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// The production client, backed by `URLSession`.
    static let live = CorveilOAuthClient(
        transport: { try await URLSession.shared.data(for: $0) })

    /// The OAuth scopes the Corveil connected app needs: read the user's orgs (the
    /// org dropdown) and mint the one per-org gateway key. From the epic
    /// (corveil/crow#1117); the backend may downscope, which is its concern.
    static let defaultScope = "orgs.read keys.provision"

    /// The loopback callback path, mounted by ``CorveilIntegrationRoutes``. The
    /// redirect URI registered at DCR time is `http://127.0.0.1:{port}{callbackPath}`.
    static let callbackPath = "/integrations/corveil/callback"

    /// The redirect URI for a given crowd HTTP port. `127.0.0.1` (not `localhost`)
    /// so it matches the loopback-peer gate on the callback route exactly, and is a
    /// loopback host the backend accepts for an `http://` redirect (RFC 8252 §7.3).
    static func redirectURI(httpPort: Int) -> String {
        "http://127.0.0.1:\(httpPort)\(callbackPath)"
    }

    // MARK: - Errors

    /// Every way the flow can fail, with enough detail to render a diagnostic.
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// The base URL couldn't be turned into the `/mcp/oauth/*` endpoints.
        case invalidBaseURL(String)
        /// The transport threw (DNS, TLS, connection refused, …).
        case transport(String)
        /// A non-2xx response that did **not** carry an OAuth error body.
        case http(status: Int, body: String)
        /// A structured OAuth error (`{"error":…,"error_description":…}`), from any endpoint.
        case oauth(error: String, description: String?)
        /// A 2xx response whose body didn't decode / lacked a required field.
        case malformedResponse(String)

        var description: String {
            switch self {
            case .invalidBaseURL(let url): return "invalid Corveil base URL: \(url)"
            case .transport(let message): return "network error: \(message)"
            case .http(let status, let body):
                return "Corveil returned HTTP \(status): \(body.prefix(200))"
            case .oauth(let error, let description):
                return description.map { "\(error): \($0)" } ?? error
            case .malformedResponse(let detail): return "unexpected Corveil response: \(detail)"
            }
        }
    }

    // MARK: - Endpoints

    /// The three `/mcp/oauth/*` endpoints, resolved against a Corveil base URL.
    struct Endpoints: Sendable, Equatable {
        let register: URL
        let authorize: URL
        let token: URL

        /// Resolve from a base URL like `https://app.corveil.example`. A trailing
        /// slash is tolerated. Returns nil for a URL with no scheme/host so the
        /// caller can surface ``Failure/invalidBaseURL(_:)`` instead of building
        /// nonsense endpoints.
        init?(baseURL: String) {
            let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            guard let root = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
                  root.scheme != nil, root.host != nil
            else { return nil }
            register = root.appendingPathComponent("mcp/oauth/register")
            authorize = root.appendingPathComponent("mcp/oauth/authorize")
            token = root.appendingPathComponent("mcp/oauth/token")
        }
    }

    // MARK: - PKCE (RFC 7636)

    /// A PKCE verifier/challenge pair. `challenge` is `BASE64URL(SHA256(verifier))`
    /// and `method` is always `S256` — the only method the backend accepts.
    struct PKCE: Sendable, Equatable {
        let verifier: String
        let challenge: String
        var method: String { "S256" }
    }

    /// Generate a fresh PKCE pair: a 32-byte random verifier (43 base64url chars,
    /// within RFC 7636's 43–128 range) and its S256 challenge.
    static func makePKCE() -> PKCE {
        let verifier = base64URL(randomBytes(32))
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    /// The S256 code challenge for a verifier: `BASE64URL(SHA256(ASCII(verifier)))`
    /// (RFC 7636 §4.2). Exposed so tests can pin it against the RFC's test vector.
    static func challenge(for verifier: String) -> String {
        base64URL(Array(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// A fresh anti-forgery `state` value (32 bytes of entropy, base64url).
    static func makeState() -> String { base64URL(randomBytes(32)) }

    // MARK: - Dynamic Client Registration (RFC 7591)

    /// What a successful DCR gives us back. `registrationAccessToken` is the RFC
    /// 7592 token that lets Crow later rotate/delete this client.
    struct Registration: Sendable, Equatable {
        let clientID: String
        let registrationAccessToken: String
        let registrationClientURI: String
        let scope: String
    }

    /// Self-register a **public** (`token_endpoint_auth_method: none`) client with
    /// the loopback redirect URI. Registers `authorization_code` + `refresh_token`
    /// grants and the `code` response type.
    func register(
        endpoints: Endpoints,
        redirectURI: String,
        clientName: String = "Crow",
        scope: String = defaultScope
    ) async throws -> Registration {
        var request = URLRequest(url: endpoints.register)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "scope": scope,
            "token_endpoint_auth_method": "none",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let json = try await sendExpectingJSON(request)
        guard let clientID = json["client_id"] as? String, !clientID.isEmpty else {
            throw Failure.malformedResponse("registration response had no client_id")
        }
        return Registration(
            clientID: clientID,
            registrationAccessToken: (json["registration_access_token"] as? String) ?? "",
            registrationClientURI: (json["registration_client_uri"] as? String) ?? "",
            scope: (json["scope"] as? String) ?? scope)
    }

    // MARK: - Authorization request (RFC 6749 §4.1.1 + PKCE)

    /// Build the browser authorize URL. Pure string assembly — no I/O.
    static func authorizeURL(
        endpoints: Endpoints,
        clientID: String,
        redirectURI: String,
        scope: String,
        state: String,
        pkce: PKCE
    ) -> URL {
        var components = URLComponents(url: endpoints.authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        return components.url!
    }

    // MARK: - Token endpoint (RFC 6749 §4.1.3 / §6)

    /// The tokens a successful exchange or refresh yields.
    struct TokenResponse: Sendable, Equatable {
        let accessToken: String
        let refreshToken: String
        let tokenType: String
        let expiresIn: Int?
        let scope: String

        /// Absolute expiry of `accessToken`, `expiresIn` seconds after `now`.
        func expiresAt(now: Date) -> Date? {
            expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        }
    }

    /// Exchange an authorization `code` for tokens, presenting the PKCE
    /// `code_verifier`. `client_id` is sent in the form body — the backend reads it
    /// there for a public client (no secret).
    func exchangeCode(
        endpoints: Endpoints,
        clientID: String,
        code: String,
        codeVerifier: String,
        redirectURI: String
    ) async throws -> TokenResponse {
        try await postToken(endpoints: endpoints, fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
            ("client_id", clientID),
        ])
    }

    /// Refresh the access token. The backend rotates the refresh token, so the
    /// returned `refreshToken` supersedes the one presented.
    func refresh(
        endpoints: Endpoints,
        clientID: String,
        refreshToken: String,
        scope: String? = nil
    ) async throws -> TokenResponse {
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]
        if let scope, !scope.isEmpty { fields.append(("scope", scope)) }
        return try await postToken(endpoints: endpoints, fields: fields)
    }

    // MARK: - Shared token POST

    private func postToken(
        endpoints: Endpoints,
        fields: [(String, String)]
    ) async throws -> TokenResponse {
        var request = URLRequest(url: endpoints.token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formURLEncode(fields).utf8)

        let json = try await sendExpectingJSON(request)
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw Failure.malformedResponse("token response had no access_token")
        }
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String) ?? "",
            tokenType: (json["token_type"] as? String) ?? "Bearer",
            expiresIn: Self.intValue(json["expires_in"]),
            scope: (json["scope"] as? String) ?? "")
    }

    // MARK: - HTTP + parsing helpers

    /// Run `request`, map transport/HTTP/OAuth failures to ``Failure``, and return
    /// the decoded JSON object on 2xx.
    private func sendExpectingJSON(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = try? JSONSerialization.jsonObject(with: data)
        let object = parsed as? [String: Any]

        guard (200...299).contains(status) else {
            // OAuth errors are a JSON `{error, error_description}` body (RFC 6749
            // §5.2 / RFC 7591 §3.2.2) — surface those specifically; fall back to a
            // raw HTTP failure otherwise.
            if let object, let error = object["error"] as? String {
                throw Failure.oauth(error: error, description: object["error_description"] as? String)
            }
            throw Failure.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        guard let object else {
            throw Failure.malformedResponse("response body was not a JSON object")
        }
        return object
    }

    /// `expires_in` may decode as an `Int`, a JSON number (`Double`), or a string —
    /// accept all three, reject the rest.
    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let double as Double: return Int(double)
        case let string as String: return Int(string)
        default: return nil
        }
    }

    /// `application/x-www-form-urlencoded` body: percent-encode each key and value
    /// with the unreserved set only (so `+`, `/`, `=` in a token never break the
    /// encoding), joined with `&`.
    static func formURLEncode(_ fields: [(String, String)]) -> String {
        fields.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&")
    }

    private static let unreserved: CharacterSet = {
        // RFC 3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Base64url without padding (RFC 7636 §A) — the encoding for PKCE verifiers,
    /// challenges, and `state`.
    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return bytes
    }
}
