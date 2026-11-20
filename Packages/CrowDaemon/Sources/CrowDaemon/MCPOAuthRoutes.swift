import CrowCore
import CrowIPC
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Crow's OAuth authorization server for `/mcp` (CROW-1465), so Claude's
/// connectors — claude.ai, Claude Desktop, the mobile apps — can connect.
///
/// | Path | Does |
/// | --- | --- |
/// | `GET /.well-known/oauth-protected-resource[/mcp]` | RFC 9728 metadata: which AS guards `/mcp` |
/// | `GET /.well-known/oauth-authorization-server` | RFC 8414 metadata |
/// | `POST /oauth/register` | RFC 7591 dynamic registration (public clients only) |
/// | `GET /oauth/authorize` | validates the request, shows the consent page |
/// | `POST /oauth/authorize` | the operator's decision, checked against the web password |
/// | `POST /oauth/token` | `authorization_code` (PKCE S256) and `refresh_token` grants |
///
/// Every path is exempt from `WebAuthMiddleware` (`MCPOAuth.isOAuthPath`) and does
/// its own auth, the way `/mcp` does. The gate that matters is the consent POST:
/// it **always** requires the web password — from loopback too — and with no
/// password configured the page refuses and issues nothing. Leaning on
/// `WebAuthMiddleware` instead would issue tokens to anyone on a daemon with no
/// password, because that gate is opt-in.
///
/// Access tokens are ordinary `MCPTokenRecord`s carrying their grant's id, so
/// `MCPRoutes` validates them exactly as it validates minted ones, and they reach
/// only `MCPToolCatalog`'s read-only allowlist.
enum MCPOAuthRoutes {

    static func mount(
        on router: Router<CrowHTTPContext>,
        boundHost: String,
        devRoot: String,
        state: MCPOAuthState,
        consentLimiter: LoginRateLimiter,
        registrationLimiter: LoginRateLimiter
    ) {
        // MARK: Discovery

        for path in MCPOAuth.protectedResourceMetadataPaths {
            router.get(RouterPath(path)) { request, context -> Response in
                guard let origin = publicOrigin(request, context) else { return badHost() }
                return metadata(origin.protectedResourceMetadata)
            }
        }
        router.get(RouterPath(MCPOAuth.authorizationServerMetadataPath)) { request, context -> Response in
            guard let origin = publicOrigin(request, context) else { return badHost() }
            return metadata(origin.authorizationServerMetadata)
        }

        // MARK: Registration

        router.post(RouterPath(MCPOAuth.registerPath)) { request, context -> Response in
            if let problem = transportProblem(request, context) {
                return oauthError(.init("invalid_request", problem), status: .forbidden)
            }
            guard registrationLimiter.allow() else {
                return oauthError(.init("invalid_request", "too many registrations; try again in a minute"),
                                  status: .tooManyRequests)
            }
            guard let buffer = try? await request.body.collect(upTo: MCPOAuth.maxBodyBytes),
                  case .object(let body)? = try? JSONDecoder().decode(
                    JSONValue.self, from: Data(buffer.readableBytesView))
            else {
                return oauthError(.init("invalid_client_metadata", "the body must be a JSON object"),
                                  status: .badRequest)
            }
            switch MCPOAuth.validateRegistration(body) {
            case .failure(let failure):
                return oauthError(failure, status: .badRequest)
            case .success(let registration):
                let now = Date()
                let client = state.register(registration, now: now)
                return json(
                    MCPOAuth.registrationResponse(clientID: client.clientID, registration: registration, issuedAt: now),
                    status: .created)
            }
        }

        // MARK: Authorization

        router.get(RouterPath(MCPOAuth.authorizePath)) { request, context -> Response in
            if let problem = transportProblem(request, context) {
                return page(MCPOAuthConsentPage.refusal(title: "Use HTTPS", message: problem), status: .forbidden)
            }
            guard let origin = publicOrigin(request, context) else { return badHost() }
            let params = MCPOAuth.uniqueParameters(MCPOAuth.formPairs(request.uri.query ?? ""))
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            // Checked before the request is even validated: with no web password
            // there is nothing to check consent against, so no request gets further.
            guard hasWebPassword(config) else {
                return page(MCPOAuthConsentPage.passwordRequired(), status: .forbidden)
            }
            let outcome = MCPOAuth.validateAuthorization(params, resource: origin.resource) { clientID in
                state.client(clientID) ?? MCPOAuthGrants.persistedClient(clientID, in: config)
            }
            switch outcome {
            case .showError(let message):
                return page(MCPOAuthConsentPage.refusal(title: "Can't connect this app", message: message),
                            status: .badRequest)
            case .redirectError(let redirectURI, let failure, let clientState):
                return redirect(MCPOAuth.redirect(
                    redirectURI, adding: MCPOAuth.errorResponse(failure, state: clientState, issuer: origin.issuer)))
            case .valid(let authorization):
                let consentID = state.openConsent(authorization)
                return page(
                    MCPOAuthConsentPage.consent(request: authorization, consentID: consentID),
                    status: .ok, redirectURI: authorization.redirectURI)
            }
        }

        router.post(RouterPath(MCPOAuth.authorizePath)) { request, context -> Response in
            if let problem = transportProblem(request, context) {
                return page(MCPOAuthConsentPage.refusal(title: "Use HTTPS", message: problem), status: .forbidden)
            }
            // A browser form post carries an Origin; it must be this server's.
            // The password is the real defence against a cross-site post, but a
            // foreign Origin has no business here at all.
            guard WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
            else {
                return page(MCPOAuthConsentPage.refusal(
                    title: "Can't connect this app", message: "The approval came from another site."),
                    status: .forbidden)
            }
            guard let origin = publicOrigin(request, context) else { return badHost() }
            guard let buffer = try? await request.body.collect(upTo: MCPOAuth.maxBodyBytes) else {
                return page(MCPOAuthConsentPage.refusal(
                    title: "Can't connect this app", message: "The form was too large."), status: .badRequest)
            }
            let pairs = MCPOAuth.formPairs(String(decoding: buffer.readableBytesView, as: UTF8.self))
            func field(_ name: String) -> String? { pairs.first(where: { $0.0 == name })?.1 }

            guard let consentID = field("consent_id"), let authorization = state.consent(consentID) else {
                return page(MCPOAuthConsentPage.refusal(
                    title: "This approval expired",
                    message: "Approval pages last ten minutes and end when crowd restarts. "
                        + "Start the connection again from the app."),
                    status: .badRequest)
            }

            if field("decision") != "approve" {
                state.closeConsent(consentID)
                return redirect(MCPOAuth.redirect(
                    authorization.redirectURI,
                    adding: MCPOAuth.errorResponse(
                        .init("access_denied", "the operator denied the request"),
                        state: authorization.state, issuer: origin.issuer)))
            }

            let ticked = Set(pairs.filter { $0.0 == "scope" }.compactMap { MCPScope.parse($0.1) })
            func retry(_ message: String, status: HTTPResponse.Status) -> Response {
                page(
                    MCPOAuthConsentPage.consent(
                        request: authorization, consentID: consentID, checked: ticked, message: message),
                    status: status, redirectURI: authorization.redirectURI)
            }

            // Re-read on every attempt: the password may have been removed since
            // the page was shown, and then nothing may be issued.
            guard let webAuth = ConfigStore.loadConfig(devRoot: devRoot)?.webAuth, !webAuth.hashB64.isEmpty else {
                state.closeConsent(consentID)
                return page(MCPOAuthConsentPage.passwordRequired(), status: .forbidden)
            }
            guard consentLimiter.allow() else {
                return retry("Too many attempts. Wait a minute, then try again.", status: .tooManyRequests)
            }
            guard let password = field("password"), PasswordHash.verify(password: password, record: webAuth) else {
                return retry("That is not the Crow web password.", status: .forbidden)
            }
            guard !ticked.isEmpty else {
                return retry("Tick at least one thing the app may do.", status: .badRequest)
            }

            state.closeConsent(consentID)
            let code = state.issueCode(for: authorization, scopes: ticked.sorted())
            return redirect(MCPOAuth.redirect(
                authorization.redirectURI,
                adding: MCPOAuth.authorizationResponse(code: code, state: authorization.state, issuer: origin.issuer)))
        }

        // MARK: Token

        router.post(RouterPath(MCPOAuth.tokenPath)) { request, context -> Response in
            if let problem = transportProblem(request, context) {
                return oauthError(.init("invalid_request", problem), status: .badRequest)
            }
            guard let buffer = try? await request.body.collect(upTo: MCPOAuth.maxBodyBytes) else {
                return oauthError(.init("invalid_request", "the body is missing or too large"), status: .badRequest)
            }
            guard let form = MCPOAuth.uniqueParameters(
                MCPOAuth.formPairs(String(decoding: buffer.readableBytesView, as: UTF8.self)))
            else {
                return oauthError(.init("invalid_request", "a parameter was repeated"), status: .badRequest)
            }
            guard let clientID = MCPOAuth.tokenClientID(form: form, authorization: request.headers[.authorization])
            else {
                return oauthError(.init("invalid_client", "client_id is required"), status: .unauthorized)
            }

            switch form["grant_type"] {
            case "authorization_code":
                return exchangeCode(form: form, clientID: clientID, devRoot: devRoot, state: state)
            case "refresh_token":
                return refresh(form: form, clientID: clientID, devRoot: devRoot)
            case nil:
                return oauthError(.init("invalid_request", "grant_type is required"), status: .badRequest)
            default:
                return oauthError(
                    .init("unsupported_grant_type", "only authorization_code and refresh_token are supported"),
                    status: .badRequest)
            }
        }
    }

    // MARK: - Grants

    static func exchangeCode(
        form: [String: String],
        clientID: String,
        devRoot: String,
        state: MCPOAuthState
    ) -> Response {
        guard let code = form["code"], !code.isEmpty,
              let verifier = form["code_verifier"],
              let redirectURI = form["redirect_uri"]
        else {
            return oauthError(
                .init("invalid_request", "code, code_verifier and redirect_uri are required"), status: .badRequest)
        }
        let invalid = MCPOAuth.Failure("invalid_grant", "the authorization code is invalid or expired")
        let replayed = MCPOAuth.Failure(
            "invalid_grant", "the authorization code was already used; the access it granted is revoked")

        let issued: MCPOAuthState.IssuedCode
        let grantID: UUID
        switch state.redeem(code) {
        case .invalid:
            return oauthError(invalid, status: .badRequest)
        case .replayed(let grantID):
            // RFC 6749 §4.1.2: a code used twice means someone else has it, so the
            // tokens it already produced are no longer trustworthy either.
            _ = try? MCPOAuthGrants.revoke(devRoot: devRoot, grantID: grantID)
            return oauthError(replayed, status: .badRequest)
        case .valid(let value, let reserved):
            issued = value
            grantID = reserved
        }

        guard issued.request.client.clientID == clientID,
              issued.request.redirectURI == redirectURI
        else { return oauthError(invalid, status: .badRequest) }
        guard MCPOAuth.isValidCodeVerifier(verifier),
              PasswordHash.constantTimeEqual(
                Array(CorveilOAuthClient.challenge(for: verifier).utf8),
                Array(issued.request.codeChallenge.utf8))
        else {
            return oauthError(.init("invalid_grant", "PKCE verification failed"), status: .badRequest)
        }
        if let resource = form["resource"],
           !MCPOAuth.resourceMatches(resource, expected: issued.request.resource) {
            return oauthError(
                .init("invalid_target", "this code is for \(issued.request.resource)"), status: .badRequest)
        }

        do {
            let result = try MCPOAuthGrants.create(
                devRoot: devRoot, request: issued.request, scopes: issued.scopes, grantID: grantID)
            // A replay that raced this exchange revoked a grant that might not
            // have been on disk yet; it flagged the code first, so check now.
            if state.finishRedemption(code) {
                _ = try? MCPOAuthGrants.revoke(devRoot: devRoot, grantID: grantID)
                return oauthError(replayed, status: .badRequest)
            }
            return tokens(result)
        } catch let failure as MCPOAuth.Failure {
            return oauthError(failure, status: .badRequest)
        } catch {
            return oauthError(.init("server_error", error.localizedDescription), status: .internalServerError)
        }
    }

    static func refresh(form: [String: String], clientID: String, devRoot: String) -> Response {
        guard let refreshToken = form["refresh_token"], !refreshToken.isEmpty else {
            return oauthError(.init("invalid_request", "refresh_token is required"), status: .badRequest)
        }
        let requested: Set<MCPScope>
        switch MCPOAuth.parseScope(form["scope"]) {
        case .failure(let failure): return oauthError(failure, status: .badRequest)
        case .success(let scopes): requested = scopes
        }
        do {
            let result = try MCPOAuthGrants.refresh(
                devRoot: devRoot, refreshToken: refreshToken, clientID: clientID,
                requestedScopes: requested, resource: form["resource"])
            return tokens(result)
        } catch let failure as MCPOAuth.Failure {
            return oauthError(failure, status: .badRequest)
        } catch {
            return oauthError(.init("server_error", error.localizedDescription), status: .internalServerError)
        }
    }

    // MARK: - Request helpers

    static func publicOrigin(_ request: Request, _ context: CrowHTTPContext) -> MCPOAuthOrigin? {
        MCPOAuthOrigin.derive(
            hostHeader: request.head.authority,
            forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
            forwardedProto: request.headers[HTTPField.Name("x-forwarded-proto")!],
            peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
    }

    static func transportProblem(_ request: Request, _ context: CrowHTTPContext) -> String? {
        MCPOAuth.transportProblem(
            peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress),
            forwardedFor: request.headers[HTTPField.Name("x-forwarded-for")!],
            forwardedProto: request.headers[HTTPField.Name("x-forwarded-proto")!])
    }

    static func hasWebPassword(_ config: AppConfig) -> Bool {
        guard let webAuth = config.webAuth else { return false }
        return !webAuth.hashB64.isEmpty
    }

    // MARK: - Responses

    private static func json(_ object: [String: JSONValue], status: HTTPResponse.Status) -> Response {
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
        // RFC 6749 §5.1: token responses must not be cached; nothing else here
        // benefits from caching either.
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("pragma")!] = "no-cache"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// Public discovery documents. CORS-open so a browser-based MCP client can
    /// read them; they carry nothing that is not already in the URL.
    private static func metadata(_ object: [String: JSONValue]) -> Response {
        let data = (try? JSONEncoder().encode(JSONValue.object(object))) ?? Data("{}".utf8)
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
        headers[.accessControlAllowOrigin] = "*"
        headers[.cacheControl] = "max-age=300"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private static func tokens(_ issued: MCPOAuthGrants.Issued) -> Response {
        json(
            MCPOAuth.tokenResponse(
                accessToken: issued.accessToken, refreshToken: issued.refreshToken, scopes: issued.scopes),
            status: .ok)
    }

    private static func oauthError(_ failure: MCPOAuth.Failure, status: HTTPResponse.Status) -> Response {
        json(failure.json, status: status)
    }

    private static func badHost() -> Response {
        oauthError(.init("invalid_request", "could not determine this server's public address"), status: .badRequest)
    }

    private static func redirect(_ location: String) -> Response {
        var headers = HTTPFields()
        headers[.location] = location
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("referrer-policy")!] = "no-referrer"
        return Response(status: .found, headers: headers)
    }

    /// An HTML page, locked down: no script, no framing, no referrer. The form may
    /// submit only to this server, and the redirect that follows a submit may go
    /// only to the request's registered redirect URI — Chrome applies
    /// `form-action` to that redirect too.
    private static func page(_ html: String, status: HTTPResponse.Status, redirectURI: String? = nil) -> Response {
        var formAction = "'self'"
        if let redirectURI, let target = MCPOAuth.origin(of: redirectURI) { formAction += " \(target)" }
        var headers: HTTPFields = [.contentType: "text/html; charset=utf-8"]
        headers[.contentSecurityPolicy] =
            "default-src 'none'; style-src 'unsafe-inline'; form-action \(formAction); "
            + "frame-ancestors 'none'; base-uri 'none'"
        headers[HTTPField.Name("x-frame-options")!] = "DENY"
        headers[.cacheControl] = "no-store"
        headers[HTTPField.Name("referrer-policy")!] = "no-referrer"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(string: html)))
    }
}
