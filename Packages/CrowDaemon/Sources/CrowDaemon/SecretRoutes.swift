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
                    let saved: WorkspaceGateway? = try ConfigStore.withConfigLock {
                        var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                        // Blank header values mean "keep stored" — the local editor
                        // prefills stripped keys with empty values (review Yellow #1).
                        let merged = try mergingPreservedHeaders(
                            incoming: gateway, stored: c.managerGateway).get()
                        c.managerGateway = merged
                        try ConfigStore.saveConfig(c, devRoot: devRoot)
                        return merged
                    }
                    return json(["saved": true, "gateway_set": saved != nil])
                } catch let e as GatewayValidationError {
                    return json(["error": e.message], status: .badRequest)
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
                    let outcome = try ConfigStore.withConfigLock { () -> (found: Bool, set: Bool) in
                        var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                        guard let idx = c.workspaces.firstIndex(where: { $0.id == uid }) else {
                            return (false, false)
                        }
                        let merged = try mergingPreservedHeaders(
                            incoming: gateway, stored: c.workspaces[idx].gateway).get()
                        c.workspaces[idx].gateway = merged
                        try ConfigStore.saveConfig(c, devRoot: devRoot)
                        return (true, merged != nil)
                    }
                    guard outcome.found else { return json(["error": "workspace not found"], status: .notFound) }
                    return json(["saved": true, "gateway_set": outcome.set])
                } catch let e as GatewayValidationError {
                    return json(["error": e.message], status: .badRequest)
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
    ///
    /// Header *values* may still be blank here — the local editor ships stripped
    /// keys with empty values. Callers must run the result through
    /// ``mergingPreservedHeaders(incoming:stored:)`` under the config lock so a
    /// blank value keeps the currently-stored secret (review Yellow #1 / CROW-593).
    static func buildGateway(_ body: GatewayBody?) -> Result<WorkspaceGateway?, GatewayValidationError> {
        guard let body, body.clear != true else { return .success(nil) }
        let url = (body.baseURL ?? "").trimmingCharacters(in: .whitespaces)
        // Keep blank-valued headers (keys present) so the merge step can restore
        // stored secrets; only drop empty *keys*.
        let headers = (body.headers ?? [:]).filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
        if url.isEmpty && headers.isEmpty { return .success(nil) }
        if url.isEmpty != headers.isEmpty {
            return .failure(GatewayValidationError(message: "a gateway needs both a base URL and at least one header, or neither"))
        }
        return .success(WorkspaceGateway(baseURL: url, customHeaders: headers))
    }

    /// Merge an incoming gateway (from the local editor) with the currently
    /// stored one so blank header values mean "keep the stored secret" — matching
    /// the help text and the `strippedForTransport` contract (review Yellow #1).
    /// `nil` incoming clears; non-nil with blank values restores from `stored`.
    ///
    /// Rejects a URL with no remaining headers after the blank-drop — that shape
    /// encodes fine but `WorkspaceGateway` refuses to decode it, which would make
    /// the next `loadConfig` return `nil` and wipe the whole config on the next
    /// write (review Red on #623).
    static func mergingPreservedHeaders(
        incoming: WorkspaceGateway?,
        stored: WorkspaceGateway?
    ) -> Result<WorkspaceGateway?, GatewayValidationError> {
        guard let incoming else { return .success(nil) }
        var headers = incoming.customHeaders
        if let stored {
            for (key, value) in headers where value.trimmingCharacters(in: .whitespaces).isEmpty {
                if let kept = stored.customHeaders[key], !kept.isEmpty {
                    headers[key] = kept
                }
            }
        }
        // Drop keys that are still blank after merge (no stored value to keep /
        // no stored gateway at all) so we don't persist empty secrets.
        headers = headers.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        let hasURL = !incoming.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        if hasURL && headers.isEmpty {
            return .failure(GatewayValidationError(
                message: "a gateway header has no value and no stored secret to keep"))
        }
        return .success(WorkspaceGateway(baseURL: incoming.baseURL, customHeaders: headers))
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
