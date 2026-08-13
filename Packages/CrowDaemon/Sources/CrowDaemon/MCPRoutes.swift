import CrowCore
import CrowIPC
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// The remote MCP endpoint: `POST /mcp` (CROW-1004).
///
/// This is the **off-box** door. Local clients get `crow mcp serve`, which bridges
/// stdio to the daemon's 0600 Unix socket and is trusted by machine locality; a
/// caller arriving here has to present a scoped bearer token minted by
/// `crow mcp token mint`.
///
/// ### Why this route is exempt from `WebAuthMiddleware`
///
/// `WebAuthMiddleware` gates on the `crow_session` **cookie**, and it is *opt-in*:
/// with no web password configured, `WebAuthGuard.authorize` returns authorized for
/// everything. Leaving `/mcp` behind it would therefore be both wrong and weak —
/// wrong because a bearer-token client has no cookie and would be 401'd, and weak
/// because on a daemon with no web password the middleware would wave anyone
/// through.
///
/// So `/mcp` is listed in `WebAuthMiddleware.isAuthExempt` and does its own auth,
/// which is **strictly stronger** than what it replaces: a valid, unexpired,
/// scope-bearing token is required on every request, with no loopback bypass and no
/// opt-in escape. `MCPRoutesTests` pins that a tokenless request is refused even
/// when no web password is set.
///
/// ### What a token can reach
///
/// Only `MCPToolCatalog` — a closed, read-only allowlist of five RPC methods. There
/// is no passthrough, so the local-only surfaces (`gateway-*`, `web-password-*`,
/// `mcp-token-*`, `run-setup`, `hook-event`, host-app open) are unreachable by
/// construction rather than by a second denial list. `MCPLedgerExportTests` asserts
/// the export set and the local-only set are disjoint.
enum MCPRoutes {

    /// Same ceiling as the `/rpc` WebSocket frame limit. A tools/call body is a few
    /// hundred bytes; this exists so an unauthenticated peer cannot make the daemon
    /// buffer megabytes before the token check.
    static let maxBodyBytes = 1 << 20

    static func mount(
        on router: Router<CrowHTTPContext>,
        commandRouter: CommandRouter,
        boundHost: String,
        devRoot: String,
        serverVersion: String
    ) {
        let server = MCPServer(serverVersion: serverVersion)

        router.post("/mcp") { request, context -> Response in
            // 1. Origin. The MCP spec requires this on every connection to defeat
            //    DNS rebinding, and mandates 403 when a present Origin is invalid.
            //    A non-browser client (the case this endpoint exists for) sends
            //    none, which passes.
            guard WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
            else {
                return jsonRPC(
                    .error(id: .null, code: MCPProtocol.ErrorCode.invalidRequest,
                           message: "Origin not allowed"),
                    status: .forbidden)
            }

            // 2. Bearer token → scopes. Deliberately before the body is read: an
            //    unauthenticated caller should not be able to make us parse JSON.
            guard let presented = MCPTokenStore.bearerToken(
                fromAuthorization: request.headers[.authorization])
            else {
                return unauthorized("An Authorization: Bearer <token> header is required")
            }
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let scopes = MCPTokenStore.scopes(for: presented, in: config.mcpTokens)
            guard !scopes.isEmpty else {
                // One message for unknown, expired, and revoked. Distinguishing them
                // would tell a probing caller whether a token was ever real.
                return unauthorized("Invalid, expired, or revoked MCP token")
            }

            // 3. Body.
            guard let buffer = try? await request.body.collect(upTo: maxBodyBytes) else {
                return jsonRPC(
                    .error(id: .null, code: MCPProtocol.ErrorCode.invalidRequest,
                           message: "Request body missing or larger than \(maxBodyBytes) bytes"),
                    status: .badRequest)
            }
            let data = Data(buffer.readableBytesView)
            guard let mcpRequest = MCPRequest.decode(data) else {
                return jsonRPC(
                    .error(id: .null, code: MCPProtocol.ErrorCode.parseError,
                           message: "Malformed JSON-RPC request"),
                    status: .badRequest)
            }

            // 4. Header/body agreement, for modern requests only. Prevents an
            //    intermediary routing on `Mcp-Method` while we execute the body.
            if let mismatch = MCPServer.headerMismatch(
                request: mcpRequest,
                methodHeader: request.headers[HTTPField.Name("mcp-method")!],
                nameHeader: request.headers[HTTPField.Name("mcp-name")!],
                versionHeader: request.headers[HTTPField.Name("mcp-protocol-version")!])
            {
                return jsonRPC(mismatch, status: .badRequest)
            }

            // 5. Dispatch.
            let outcome = await server.handle(mcpRequest, scopes: scopes) { method, params in
                // Every method reaching here came from `MCPToolCatalog`, never from
                // the wire. The synthetic id is required because the daemon's
                // `JSONRPCRequest.id` is a non-optional Int; MCP correlates on its
                // own id, which never leaves this closure.
                let response = await commandRouter.handle(
                    request: JSONRPCRequest(id: 0, method: method, params: params))
                if let error = response.error {
                    throw MCPBridgeError(message: error.message)
                }
                return response.result ?? [:]
            }

            switch outcome {
            case .accepted:
                // A notification. The spec requires 202 with no body.
                return Response(status: .accepted)
            case .reply(let response):
                return jsonRPC(response, status: .ok)
            case .badRequest(let response):
                return jsonRPC(response, status: .badRequest)
            case .unknownMethod(let response):
                // 404 + a JSON-RPC error body: that combination is what lets a client
                // tell a modern MCP server from a legacy HTTP+SSE server that does
                // not host this endpoint at all.
                return jsonRPC(response, status: .notFound)
            }
        }

        // Revision 2026-07-28 removed the GET stream and protocol-level sessions.
        // A server that supports only this revision answers GET and DELETE on the
        // MCP endpoint with 405, which is also what tells an older client to stop
        // trying to open a standalone SSE stream.
        router.get("/mcp") { _, _ -> Response in methodNotAllowed() }
        router.delete("/mcp") { _, _ -> Response in methodNotAllowed() }
    }

    // MARK: - Responses

    /// A daemon-side RPC failure, surfaced to the model as a tool execution error
    /// rather than a transport fault.
    private struct MCPBridgeError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func jsonRPC(_ response: MCPResponse, status: HTTPResponse.Status) -> Response {
        Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: response.encoded())))
    }

    /// 401 with a `WWW-Authenticate` challenge, so a client knows *how* to
    /// authenticate rather than only that it failed.
    private static func unauthorized(_ message: String) -> Response {
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
        headers[.wwwAuthenticate] = #"Bearer realm="crow-mcp""#
        let body = MCPResponse.error(
            id: .null, code: MCPProtocol.ErrorCode.invalidRequest, message: message)
        return Response(
            status: .unauthorized,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: body.encoded())))
    }

    private static func methodNotAllowed() -> Response {
        var headers: HTTPFields = [.contentType: "application/json; charset=utf-8"]
        headers[.allow] = "POST"
        let body = MCPResponse.error(
            id: .null,
            code: MCPProtocol.ErrorCode.invalidRequest,
            message: "The MCP endpoint accepts POST only; this revision has no GET stream or sessions")
        return Response(
            status: .methodNotAllowed,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: body.encoded())))
    }
}
