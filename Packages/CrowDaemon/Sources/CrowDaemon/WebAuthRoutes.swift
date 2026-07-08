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
        let path = request.uri.path
        if path == "/login" || path == "/logout" || path == "/health" || path == "/brand.svg" {
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
        if request.method == .get, (request.headers[.accept] ?? "").contains("text/html") {
            return StaticAssets.loginPage(webDir: webDir)
        }
        return Response(status: .unauthorized)
    }
}
