import CrowIPC
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

/// One-shot JSON-RPC over `POST /rpc` (CROW-1220).
///
/// The WebSocket at the same path stays the browser's live channel. This POST
/// is the CLI fallback when a sandboxed agent cannot connect to `crow.sock`
/// but can still reach loopback TCP. Same `CommandRouter`, same Origin +
/// web-auth + `localOnlyDenial` gates as the WS upgrade — a missing `Origin` from
/// a loopback peer is `local-direct`, matching a native WS client.
enum RPCHTTPHandler {
    static let maxBodyBytes = CrowDaemon.maxWebSocketFrameSize

    static func mount(
        on router: Router<CrowHTTPContext>,
        commandRouter: CommandRouter,
        boundHost: String,
        devRoot: String
    ) {
        router.post("/rpc") { request, context -> Response in
            let originOK = WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
            guard originOK else {
                return jsonRPC(
                    .error(id: 0, code: RPCErrorCode.invalidRequest, message: "Origin not allowed"),
                    status: .forbidden)
            }

            // Middleware already authorized; locality still matters for
            // `localOnlyDenial` (gateway, hook-event, …).
            let localDirect = WebAuthGuard.isLocalDirect(
                remoteAddress: context.remoteAddress,
                forwardedFor: request.headers[HTTPField.Name("x-forwarded-for")!])

            guard let buffer = try? await request.body.collect(upTo: maxBodyBytes) else {
                return jsonRPC(
                    .error(
                        id: 0, code: RPCErrorCode.parseError,
                        message: "Request body missing or larger than \(maxBodyBytes) bytes"),
                    status: .badRequest)
            }
            let data = Data(buffer.readableBytesView)
            guard let rpcRequest = try? JSONDecoder().decode(JSONRPCRequest.self, from: data) else {
                return jsonRPC(
                    .error(id: 0, code: RPCErrorCode.parseError, message: "Malformed JSON-RPC request"),
                    status: .badRequest)
            }

            if !localDirect, let deny = RPCWebSocketHandler.localOnlyDenial(
                for: rpcRequest, devRoot: devRoot
            ) {
                return jsonRPC(
                    .error(id: rpcRequest.id, code: RPCErrorCode.invalidParams, message: deny),
                    status: .ok)
            }

            let response = await commandRouter.handle(request: rpcRequest)
            return jsonRPC(response, status: .ok)
        }
    }

    private static func jsonRPC(_ response: JSONRPCResponse, status: HTTPResponse.Status) -> Response {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(response)) ?? Data()
        return Response(
            status: status,
            headers: [.contentType: "application/json; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
