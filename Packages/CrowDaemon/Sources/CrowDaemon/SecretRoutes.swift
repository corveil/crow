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
/// These are dedicated HTTP POSTs because the handler then has the peer address
/// + `X-Forwarded-For` in hand for the locality check, and can Origin-check each
/// write so a malicious page in the *local* browser can't drive it via CSRF.
/// Mirrors the `WebAuthRoutes` POST pattern; both sit behind `WebAuthMiddleware`.
/// This is the path the **browser** uses.
///
/// The **CLI** reaches the same surfaces over the Unix socket through the
/// `gateway-*` / `web-password-*` JSON-RPC methods (CROW-815). Those are safe
/// despite the shared `/rpc` router being transport-agnostic *only* because
/// every one of them is listed in
/// ``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``, which refuses them for
/// non-local peers — reads included, since `gateway-get` with `reveal` returns
/// the auth headers. Validation is not duplicated: those handlers call
/// ``buildGateway(_:)`` and ``mergingPreservedHeaders(incoming:stored:)`` below.
///
/// So there are two doors to one room. Removing either the RPC gate or these
/// routes' `gateOK` check re-opens the hole this type exists to close.
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

        // Mint or revoke an MCP bearer token. Local-only (see type doc) — a remote
        // peer must not be able to issue itself the credential that gates remote MCP
        // access. Shares its decisions with the `mcp-token-*` RPCs through
        // `MCPTokenRPC`, so the browser and `crow mcp token` cannot drift (CROW-1004).
        router.post("/config/mcp-tokens") { request, context -> Response in
            guard gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            guard let body = await decode(MCPTokenBody.self, request) else {
                return json(["error": "a JSON body is required"], status: .badRequest)
            }

            do {
                switch body.action {
                case "mint":
                    let minted = try MCPTokenRPC.mint(
                        name: body.name ?? "",
                        rawScopes: body.scopes ?? [],
                        noExpiry: body.noExpiry == true,
                        expiresInSeconds: body.expiresInSeconds)
                    try ConfigStore.withConfigLock {
                        var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                        c.mcpTokens.append(minted.record)
                        try ConfigStore.saveConfig(c, devRoot: devRoot)
                    }
                    // The one and only time the plaintext leaves the daemon. It
                    // travels over a loopback connection to a local browser — the
                    // same trust boundary `crow mcp token mint` uses.
                    return json([
                        "saved": true,
                        "token": minted.plaintext,
                        "warning": "This token is shown once and cannot be recovered.",
                        "id": minted.record.id.uuidString,
                        "name": minted.record.name,
                        "prefix": minted.record.prefix,
                    ])

                case "revoke":
                    let removed = try ConfigStore.withConfigLock { () -> MCPTokenRecord in
                        var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                        let token = try MCPTokenRPC.tokenToRevoke(
                            id: body.id, name: body.name, in: c.mcpTokens)
                        c.mcpTokens.removeAll { $0.id == token.id }
                        try ConfigStore.saveConfig(c, devRoot: devRoot)
                        return token
                    }
                    return json(["revoked": true, "id": removed.id.uuidString, "name": removed.name])

                default:
                    return json(["error": "action must be \"mint\" or \"revoke\""], status: .badRequest)
                }
            } catch let error as MCPTokenRPC.Invalid {
                return json(["error": error.message], status: .badRequest)
            } catch {
                return json(
                    ["error": "failed to save: \(error.localizedDescription)"],
                    status: .internalServerError)
            }
        }

        // Set or clear the Corveil connection (CROW-1120). Local-only (see type
        // doc) — the block holds OAuth tokens, so a remote peer must not author or
        // clear it. This is the browser's half of the write path; the CLI's is the
        // `corveil-connect` / `corveil-disconnect` RPC. Both share the decode +
        // secret-safe merge in `CorveilConnectionRPC`, so the Integrations tab and
        // `crow corveil` cannot drift on what a blank field means.
        router.post("/config/corveil-connection") { request, context -> Response in
            guard gateOK(request, context, boundHost: boundHost) else {
                return json(["error": "local-only"], status: .forbidden)
            }
            guard let body = await decode(CorveilConnectionBody.self, request) else {
                return json(["error": "a JSON body is required"], status: .badRequest)
            }

            // Disconnect: drop the whole block. Gateway resolution and the log
            // collector stop using it on the next read.
            if body.clear == true {
                do {
                    let wasConnected = try ConfigStore.withConfigLock { () -> Bool in
                        var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                        let was = !(c.corveilConnection?.isEmpty ?? true)
                        c.corveilConnection = nil
                        try ConfigStore.saveConfig(c, devRoot: devRoot)
                        return was
                    }
                    return json(["saved": true, "connected": false, "was_connected": wasConnected])
                } catch {
                    return json(
                        ["error": "failed to save: \(error.localizedDescription)"],
                        status: .internalServerError)
                }
            }

            // Parse expiry (ISO-8601) up front so a bad value is a 400, not a
            // silent drop — matching the RPC's `decodeInput`.
            var expiresAt: Date?
            if let raw = body.accessTokenExpiresAt?.trimmingCharacters(in: .whitespaces),
               !raw.isEmpty {
                guard let date = ISO8601DateFormatter().date(from: raw) else {
                    return json(
                        ["error": "accessTokenExpiresAt must be an ISO-8601 timestamp"],
                        status: .badRequest)
                }
                expiresAt = date
            }
            let input = CorveilConnectionRPC.Input(
                baseURL: body.baseURL,
                clientID: body.clientID,
                userID: body.userId,
                userEmail: body.userEmail,
                userName: body.userName,
                accessToken: body.accessToken,
                refreshToken: body.refreshToken,
                registrationAccessToken: body.registrationAccessToken,
                accessTokenExpiresAt: expiresAt)
            do {
                try ConfigStore.withConfigLock {
                    var c = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                    c.corveilConnection = try CorveilConnectionRPC.merge(
                        input, into: c.corveilConnection)
                    try ConfigStore.saveConfig(c, devRoot: devRoot)
                }
                return json(["saved": true, "connected": true])
            } catch let error as CorveilConnectionRPC.Invalid {
                return json(["error": error.message], status: .badRequest)
            } catch {
                return json(
                    ["error": "failed to save: \(error.localizedDescription)"],
                    status: .internalServerError)
            }
        }
    }

    /// Body of `POST /config/corveil-connection`. All fields optional; a blank or
    /// absent token keeps the stored secret (matching the gateway route's
    /// blank-value contract). `clear: true` disconnects. `accessTokenExpiresAt` is
    /// an ISO-8601 string.
    struct CorveilConnectionBody: Decodable {
        let baseURL: String?
        let clientID: String?
        let userId: String?
        let userEmail: String?
        let userName: String?
        let accessToken: String?
        let refreshToken: String?
        let registrationAccessToken: String?
        let accessTokenExpiresAt: String?
        let clear: Bool?
    }

    /// Body of `POST /config/mcp-tokens`. One shape for both actions — `mint` reads
    /// `name`/`scopes`/expiry, `revoke` reads `id` or `name`.
    struct MCPTokenBody: Decodable {
        let action: String?
        let name: String?
        let scopes: [String]?
        let expiresInSeconds: Int?
        let noExpiry: Bool?
        let id: String?
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
    ///
    /// This is also where the quote rules live for **both** writers (CROW-969):
    /// the web POSTs above and the `gateway-set` RPC, which funnels
    /// `SecretsRPC.decodeHeaderLines` straight into here. Enforcing them at this
    /// one chokepoint is what keeps the CLI's and the browser's error text
    /// identical for the same mistake.
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
        // CROW-969: reject what a shell left literally quoted. Runs after the
        // both-or-neither check so the structural error still wins, and iterates
        // sorted so the header named in the error is deterministic when several
        // are wrong.
        //
        // Blank values are exempt by construction — `isQuoteWrapped` passes them —
        // because a blank value is the "keep the stored secret" signal that
        // `mergingPreservedHeaders` resolves below. The messages name the header
        // and never its value: this string becomes an HTTP 400 body and an RPC
        // error, both of which land in logs.
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            if WorkspaceGateway.headerNameHasStrayQuote(name) {
                return .failure(GatewayValidationError(
                    message: "header name '\(name)' carries a quote character — quote the whole 'Name: Value' pair in your shell, not inside it"))
            }
            if WorkspaceGateway.isQuoteWrapped(value) {
                return .failure(GatewayValidationError(
                    message: "the value for header '\(name)' is wrapped in quote characters, which would be sent as part of the credential — remove them"))
            }
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
    ///
    /// ⚠️ The CROW-969 quote rules deliberately do **not** run here. This function
    /// substitutes a *stored* value for each blank one, and a stored value is
    /// exactly what may be quote-wrapped — a config written before `buildGateway`
    /// started rejecting them. Checking here would make `--header "X-Api-Key:"`
    /// (the documented way to change a base URL without restating the key) fail on
    /// any pre-existing bad secret, and would permanently break the web gateway
    /// editor for that workspace, since it always sends blank values for stored
    /// keys — locking the user out of fixing the very config the rule is about.
    /// Already-stored values are warned about at launch by `GatewayResolver`.
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
