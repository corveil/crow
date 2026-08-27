import CrowCore
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// The browser-facing HTTP surface of the Corveil **Connect** (OAuth) flow
/// (CROW-1119): the loopback callback the authorization server redirects to, plus
/// the Connect trigger that self-registers the client and opens the consent page.
///
///   - `POST /integrations/corveil/connect` — gated exactly like the other secret
///     writes (``SecretRoutes/gateOK`` = local-direct **and** same-origin): a
///     remote/proxied session, even a logged-in one, is refused, and a cross-site
///     page in the local browser can't drive it. Registers a fresh public PKCE
///     client (DCR), stashes the in-flight `state`/verifier, opens the browser, and
///     returns the authorize URL.
///   - `GET /integrations/corveil/callback` — the redirect target. Gated
///     **local-direct** only (``SecretRoutes/isLocalDirect`` = loopback peer, no
///     `X-Forwarded-For`): a top-level browser redirect carries no `Origin`, so the
///     CSRF arm of `gateOK` doesn't apply, and the redirect must be reachable by a
///     plain navigation. Validates `state` against the stored pending record
///     (single-use), exchanges the `code` (with the PKCE `code_verifier`) for
///     tokens, and stores them through the local-only config door.
///
/// Same shape and gating rationale as ``SecretRoutes`` / ``CorveilRoutes`` /
/// ``AutostartRoutes``: dedicated HTTP routes rather than JSON-RPC methods, because
/// the handlers need the peer address + `X-Forwarded-For` for the locality check,
/// and because writing the OAuth tokens is a host-local privilege a remote peer
/// must not hold. The token exchange/refresh primitives live in
/// ``CorveilOAuthClient``; the pending-state store and config write in
/// ``CorveilConnectionStore``.
enum CorveilIntegrationRoutes {
    static let connectPath = "/integrations/corveil/connect"
    static let callbackPath = CorveilOAuthClient.callbackPath

    /// Persist freshly-exchanged tokens. Injected in tests; defaults to the
    /// local-only config write in ``CorveilConnectionPersistence``.
    typealias TokenPersist =
        @Sendable (_ baseURL: String, _ clientID: String, _ tokens: CorveilOAuthTokens) throws -> Void

    static func mount(
        on router: Router<CrowHTTPContext>,
        boundHost: String,
        devRoot: String,
        httpPort: Int,
        pending: CorveilPendingAuthStore,
        client: CorveilOAuthClient = .live,
        scope: String = CorveilOAuthClient.defaultScope,
        openBrowser: @escaping @Sendable (URL) -> Void = defaultOpenBrowser,
        persist: TokenPersist? = nil
    ) {
        let redirectURI = CorveilOAuthClient.redirectURI(httpPort: httpPort)
        let store: TokenPersist = persist ?? { baseURL, clientID, tokens in
            try CorveilConnectionPersistence.store(
                devRoot: devRoot, baseURL: baseURL, clientID: clientID, tokens: tokens)
        }

        // MARK: Connect — start the flow. Local-only + same-origin (CSRF).
        router.post(RouterPath(connectPath)) { request, context -> Response in
            guard SecretRoutes.gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            struct Body: Decodable { let baseURL: String? }
            let body = await decode(Body.self, request)

            // The base URL comes from the request (the Integrations UI supplies it),
            // falling back to a previously-connected base URL. There is no hardcoded
            // production default — the connection's base URL is configuration.
            let requested = (body?.baseURL ?? "").trimmingCharacters(in: .whitespaces)
            let stored = ConfigStore.loadConfig(devRoot: devRoot)?.corveilConnection?.baseURL ?? ""
            let baseURL = requested.isEmpty ? stored : requested
            guard !baseURL.isEmpty else {
                return json(["error": "a Corveil base URL is required"], status: .badRequest)
            }
            guard let endpoints = CorveilOAuthClient.Endpoints(baseURL: baseURL) else {
                return json(["error": CorveilOAuthClient.Failure.invalidBaseURL(baseURL).description],
                            status: .badRequest)
            }

            // Self-register a fresh public client. Fresh per connect: the backend
            // issues a client_id per install and refuses cross-org reuse.
            let registration: CorveilOAuthClient.Registration
            do {
                registration = try await client.register(
                    endpoints: endpoints, redirectURI: redirectURI, scope: scope)
            } catch {
                return json(["error": describe(error)], status: .badGateway)
            }

            let pkce = CorveilOAuthClient.makePKCE()
            let state = CorveilOAuthClient.makeState()
            pending.put(CorveilPendingAuthorization(
                state: state,
                codeVerifier: pkce.verifier,
                clientID: registration.clientID,
                redirectURI: redirectURI,
                baseURL: baseURL,
                registrationAccessToken: registration.registrationAccessToken,
                scope: registration.scope,
                createdAt: Date()))

            let authorizeURL = CorveilOAuthClient.authorizeURL(
                endpoints: endpoints, clientID: registration.clientID, redirectURI: redirectURI,
                scope: registration.scope, state: state, pkce: pkce)
            openBrowser(authorizeURL)
            return json(["authorizeURL": authorizeURL.absoluteString])
        }

        // MARK: Callback — the loopback redirect target. Local-direct only.
        router.get(RouterPath(callbackPath)) { request, context -> Response in
            guard SecretRoutes.isLocalDirect(request, context) else {
                return page(title: "Not available",
                            message: "This page is only reachable from the machine running Crow.",
                            success: false, status: .forbidden)
            }

            let query = request.uri.queryParameters
            func param(_ name: String) -> String {
                query[name[...]].map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            }

            // The authorization server signals a denial/error by redirecting with
            // `error` (+ optional `error_description`) instead of a `code`.
            let oauthError = param("error")
            if !oauthError.isEmpty {
                let description = param("error_description")
                return page(title: "Corveil sign-in was cancelled",
                            message: description.isEmpty ? oauthError : "\(oauthError): \(description)",
                            success: false, status: .badRequest)
            }

            let code = param("code")
            let state = param("state")
            guard !code.isEmpty, !state.isEmpty else {
                return page(title: "Invalid sign-in response",
                            message: "The Corveil redirect was missing its authorization code or state.",
                            success: false, status: .badRequest)
            }

            // `state` validation: the callback must match a pending authorization we
            // started (single-use, unexpired). A mismatch means a forged, replayed,
            // or stale callback.
            guard let flow = pending.consume(state: state) else {
                return page(title: "Sign-in link expired",
                            message: "This Corveil sign-in link has already been used or has expired. "
                                + "Start the connection again from Crow.",
                            success: false, status: .badRequest)
            }

            let response: CorveilOAuthClient.TokenResponse
            do {
                response = try await client.exchangeCode(
                    endpoints: CorveilOAuthClient.Endpoints(baseURL: flow.baseURL)!,
                    clientID: flow.clientID, code: code,
                    codeVerifier: flow.codeVerifier, redirectURI: flow.redirectURI)
            } catch {
                return page(title: "Couldn't complete sign-in",
                            message: describe(error), success: false, status: .badRequest)
            }

            let tokens = CorveilOAuthTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken,
                registrationAccessToken: flow.registrationAccessToken,
                accessTokenExpiresAt: response.expiresAt(now: Date()))
            do {
                try store(flow.baseURL, flow.clientID, tokens)
            } catch {
                return page(title: "Signed in, but couldn't save",
                            message: "Crow received the Corveil tokens but failed to store them: "
                                + error.localizedDescription,
                            success: false, status: .internalServerError)
            }

            return page(title: "Connected to Corveil",
                        message: "You can close this tab and return to Crow.",
                        success: true, status: .ok)
        }
    }

    // MARK: - Browser opener

    /// Open `url` in the host's default browser. Best-effort and fire-and-forget:
    /// Connect still returns the authorize URL, so a failed launch degrades to
    /// "click this link" rather than blocking the flow.
    static let defaultOpenBrowser: @Sendable (URL) -> Void = { url in
        #if os(macOS)
        launchDetached("/usr/bin/open", [url.absoluteString])
        #else
        launchDetached("/usr/bin/env", ["xdg-open", url.absoluteString])
        #endif
    }

    private static func launchDetached(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Reap the child so the long-lived daemon doesn't accumulate zombies
        // (matches `launchHostProcess` in RPCHandlers).
        process.terminationHandler = { _ in }
        try? process.run()
    }

    // MARK: - HTTP helpers

    private static func describe(_ error: Error) -> String {
        (error as? CorveilOAuthClient.Failure)?.description ?? error.localizedDescription
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ request: Request) async -> T? {
        guard let buffer = try? await request.body.collect(upTo: 64 * 1024) else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(buffer.readableBytesView))
    }

    private static func json(_ dict: [String: Any], status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// A minimal self-contained HTML result page for the callback (no external
    /// assets — this renders in the browser after the redirect).
    static func page(
        title: String, message: String, success: Bool, status: HTTPResponse.Status
    ) -> Response {
        let accent = success ? "#1a7f37" : "#b42318"
        let mark = success ? "✓" : "✕"
        let html = """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                 margin: 0; display: grid; min-height: 100vh; place-items: center;
                 background: Canvas; color: CanvasText; }
          .card { max-width: 30rem; padding: 2rem 2.25rem; text-align: center; }
          .mark { width: 3rem; height: 3rem; margin: 0 auto 1rem; border-radius: 50%;
                  display: grid; place-items: center; font-size: 1.5rem; color: #fff;
                  background: \(accent); }
          h1 { font-size: 1.25rem; margin: 0 0 .5rem; }
          p { margin: 0; opacity: .8; }
        </style></head>
        <body><main class="card">
          <div class="mark">\(mark)</div>
          <h1>\(escape(title))</h1>
          <p>\(escape(message))</p>
        </main></body></html>
        """
        return Response(
            status: status,
            headers: [.contentType: "text/html; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: html)))
    }

    /// Escape the five HTML-significant characters so a provider-supplied
    /// `error_description` can't inject markup into the result page.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
