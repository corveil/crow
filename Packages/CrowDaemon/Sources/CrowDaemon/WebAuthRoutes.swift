import CrowCore
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// HTTP-side web auth (CROW-593): a middleware that gates every route except the
/// login/health endpoints, plus `POST /login` (verify password → issue session
/// cookie) and `POST /logout`. Pairs with the WS-upgrade gates in
/// `RPCWebSocketHandler` / `TerminalWebSocket`.
enum WebAuthRoutes {
    struct LoginBody: Decodable { let password: String }

    static func mount(
        on router: Router<CrowHTTPContext>,
        sessions: SessionStore,
        loginLimiter: LoginRateLimiter,
        devRoot: String,
        webDir: String?
    ) {
        router.add(middleware: WebAuthMiddleware<CrowHTTPContext>(
            sessions: sessions, devRoot: devRoot, webDir: webDir))

        router.post("/login") { request, _ -> Response in
            guard loginLimiter.allow() else { return Response(status: .tooManyRequests) }
            let buffer = try await request.body.collect(upTo: 4096)
            let password = (try? JSONDecoder().decode(LoginBody.self, from: Data(buffer.readableBytesView)))?.password
            guard let webAuth = ConfigStore.loadConfig(devRoot: devRoot)?.webAuth, !webAuth.hashB64.isEmpty,
                  let password, PasswordHash.verify(password: password, record: webAuth) else {
                return Response(status: .unauthorized)
            }
            let token = sessions.issue()
            var headers = HTTPFields()
            headers[.setCookie] = WebAuthGuard.setCookieValue(token: token, ttl: sessions.ttl)
            return Response(status: .noContent, headers: headers, body: .init())
        }

        router.post("/logout") { request, _ -> Response in
            sessions.revoke(WebAuthGuard.sessionToken(fromCookie: request.headers[.cookie]))
            var headers = HTTPFields()
            headers[.setCookie] = WebAuthGuard.clearCookieValue()
            return Response(status: .noContent, headers: headers, body: .init())
        }
    }
}

/// Requires `WebAuthGuard.authorize` for every route except `/login`, `/logout`,
/// `/health`. Unauthenticated navigational GETs get the login page (200); other
/// unauthenticated requests get 401.
struct WebAuthMiddleware<Context: RemoteAddressRequestContext>: RouterMiddleware {
    let sessions: SessionStore
    let devRoot: String
    let webDir: String?

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if Self.isAuthExempt(path: request.uri.path) {
            return try await next(request, context)
        }
        let decision = WebAuthGuard.authorize(
            remoteAddress: context.remoteAddress,
            cookieHeader: request.headers[.cookie],
            forwardedFor: request.headers[HTTPField.Name("x-forwarded-for")!],
            forwardedProto: request.headers[HTTPField.Name("x-forwarded-proto")!],
            configProvider: { ConfigStore.loadConfig(devRoot: devRoot) },
            sessions: sessions)
        if decision.isAuthorized {
            return try await next(request, context)
        }
        if Self.serveLoginPageForUnauthorized(method: request.method, accept: request.headers[.accept]) {
            return StaticAssets.loginPage(webDir: webDir)
        }
        return Response(status: .unauthorized)
    }

    /// Paths served without the web-auth gate: the login/logout endpoints, the
    /// health probe, and the brand asset the login page needs before auth. Every
    /// other path (incl. `/auth/check`, `/`, `/rpc`, the secret POSTs) is gated.
    static func isAuthExempt(path: String) -> Bool {
        path == "/login" || path == "/logout" || path == "/health" || path == "/brand.svg"
    }

    /// For an unauthorized request, whether to answer with the login page (200)
    /// rather than a bare 401: only for navigational GETs (an `Accept: text/html`
    /// GET), so XHR/fetch and WS-adjacent probes still get a clean 401.
    static func serveLoginPageForUnauthorized(method: HTTPRequest.Method, accept: String?) -> Bool {
        method == .get && (accept ?? "").contains("text/html")
    }
}
