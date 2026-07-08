import CrowCore
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// Local-only management of secret configuration (CROW-593).
///
/// The web-access password and the AI gateways (base URL + auth headers) may
/// only be changed from a **local-direct** connection — a browser at the
/// loopback address with no `X-Forwarded-For`, or the machine itself. A
/// proxied/remote session (even a logged-in one) is refused, so:
///   - a password that gates remote access can't be changed or cleared by a
///     remote client, and
///   - gateway auth-header secrets never travel to or from a remote browser
///     (they stay stripped / read-only there, per `SettingsSecrets`).
///
/// These are dedicated HTTP POSTs rather than JSON-RPC methods precisely so the
/// handler has the peer address + `X-Forwarded-For` in hand for the locality
/// check — the shared `/rpc` WebSocket router is transport-agnostic and can't
/// tell a local caller from a logged-in remote one. Each write is also
/// Origin-checked, so a malicious page in the *local* browser can't drive it via
/// CSRF. Mirrors the `WebAuthRoutes` POST pattern; both sit behind
/// `WebAuthMiddleware`.
enum SecretRoutes {
    static func mount(on router: Router<CrowHTTPContext>, boundHost: String, devRoot: String) {
        // Locality probe: tells the web UI whether THIS connection may manage
        // secrets, so it renders editable controls locally and read-only remotely.
        router.get("/auth/context") { request, context -> Response in
            json(["local": isLocalDirect(request, context)])
        }

        // Set or clear the web-access password. Local-only (see type doc).
        router.post("/config/web-password") { request, context -> Response in
            guard gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            struct Body: Decodable { let password: String?; let clear: Bool? }
            let body = await decode(Body.self, request)
            let clear = body?.clear == true
            if !clear, (body?.password?.isEmpty ?? true) {
                return json(["error": "password must be a non-empty string (or clear: true)"], status: .badRequest)
            }
            do {
                let isSet = try ConfigStore.withConfigLock { () -> Bool in
                    var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                    c.webAuth = clear ? nil : PasswordHash.make(password: body!.password!)
                    try ConfigStore.saveConfig(c, devRoot: devRoot)
                    return c.webAuth != nil
                }
                return json(["saved": true, "password_set": isSet])
            } catch {
                return json(["error": "failed to save: \(error.localizedDescription)"], status: .internalServerError)
            }
        }

        // Set or clear the Manager AI gateway. Local-only.
        router.post("/config/manager-gateway") { request, context -> Response in
            guard gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            switch buildGateway(await decode(GatewayBody.self, request)) {
            case .failure(let e):
                return json(["error": e.message], status: .badRequest)
            case .success(let gateway):
                do {
                    try ConfigStore.withConfigLock {
                        var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                        c.managerGateway = gateway
                        try ConfigStore.saveConfig(c, devRoot: devRoot)
                    }
                    return json(["saved": true, "gateway_set": gateway != nil])
                } catch {
                    return json(["error": "failed to save: \(error.localizedDescription)"], status: .internalServerError)
                }
            }
        }

        // Set or clear a per-workspace AI gateway (matched by workspace id). Local-only.
        router.post("/config/workspace-gateway") { request, context -> Response in
            guard gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            guard let body = await decode(WorkspaceGatewayBody.self, request),
                  let uid = UUID(uuidString: body.workspaceId) else {
                return json(["error": "a valid workspaceId is required"], status: .badRequest)
            }
            switch buildGateway(body.gatewayBody) {
            case .failure(let e):
                return json(["error": e.message], status: .badRequest)
            case .success(let gateway):
                do {
                    let found = try ConfigStore.withConfigLock { () -> Bool in
                        var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                        guard let idx = c.workspaces.firstIndex(where: { $0.id == uid }) else { return false }
                        c.workspaces[idx].gateway = gateway
                        try ConfigStore.saveConfig(c, devRoot: devRoot)
                        return true
                    }
                    guard found else { return json(["error": "workspace not found"], status: .notFound) }
                    return json(["saved": true, "gateway_set": gateway != nil])
                } catch {
                    return json(["error": "failed to save: \(error.localizedDescription)"], status: .internalServerError)
                }
            }
        }
    }

    // MARK: - Gateway body + validation

    struct GatewayBody: Decodable {
        let baseURL: String?
        let headers: [String: String]?
        let clear: Bool?
    }

    struct WorkspaceGatewayBody: Decodable {
        let workspaceId: String
        let baseURL: String?
        let headers: [String: String]?
        let clear: Bool?
        var gatewayBody: GatewayBody { GatewayBody(baseURL: baseURL, headers: headers, clear: clear) }
    }

    /// A gateway body that violates the both-or-neither invariant.
    struct GatewayValidationError: Error { let message: String }

    /// Build the gateway to persist (or `nil` to clear) from a request body,
    /// enforcing `WorkspaceGateway`'s both-or-neither invariant: a base URL and
    /// at least one header, or neither. `clear: true` (or an all-empty body)
    /// clears it.
    static func buildGateway(_ body: GatewayBody?) -> Result<WorkspaceGateway?, GatewayValidationError> {
        guard let body, body.clear != true else { return .success(nil) }
        let url = (body.baseURL ?? "").trimmingCharacters(in: .whitespaces)
        let headers = (body.headers ?? [:]).filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        if url.isEmpty && headers.isEmpty { return .success(nil) }
        if url.isEmpty != headers.isEmpty {
            return .failure(GatewayValidationError(message: "a gateway needs both a base URL and at least one header, or neither"))
        }
        return .success(WorkspaceGateway(baseURL: url, customHeaders: headers))
    }

    // MARK: - Gating

    static func isLocalDirect(_ request: Request, _ context: CrowHTTPContext) -> Bool {
        WebAuthGuard.isLocalDirect(
            remoteAddress: context.remoteAddress,
            forwardedFor: request.headers[HTTPField.Name("x-forwarded-for")!])
    }

    /// A secret write is allowed only from a same-origin request (anti-CSRF) on a
    /// local-direct connection.
    static func gateOK(_ request: Request, _ context: CrowHTTPContext, boundHost: String) -> Bool {
        let originOK = WebSocketOriginGuard.isAllowedOrigin(
            request.headers[.origin],
            boundHost: boundHost,
            forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
            peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
        return originOK && isLocalDirect(request, context)
    }

    // MARK: - HTTP helpers

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
}
