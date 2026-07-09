import CrowCore
import CrowIPC
import CrowPersistence
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket

/// Serves the existing JSON-RPC protocol over a WebSocket at `/rpc`.
///
/// One JSON object per WebSocket message: decode a ``JSONRPCRequest``, run it
/// through the shared ``CommandRouter`` (the very same router the Unix-socket
/// server uses), and write the ``JSONRPCResponse`` back. No semaphore bridge —
/// unlike `SocketServer`, we're already in an async context (CROW-581).
///
/// A single writer task owns `outbound`: both RPC responses and `EventHub`
/// broadcast notifications flow through one per-connection `AsyncStream`, so
/// they never interleave frames on the socket (CROW-581, M-D).
enum RPCWebSocketHandler {
    static func mount(
        on router: Router<CrowWSContext>,
        commandRouter: CommandRouter,
        eventHub: EventHub,
        boundHost: String,
        sessions: SessionStore,
        devRoot: String
    ) {
        router.ws("/rpc") { request, context in
            // Reject cross-site upgrades (Origin) AND unauthenticated non-local
            // access (web password) — `/rpc` reaches `add-worktree`, which shells
            // out to git (CROW-581 review, CROW-593).
            let originOK = WebSocketOriginGuard.isAllowedOrigin(
                request.headers[.origin],
                boundHost: boundHost,
                forwardedHost: request.headers[HTTPField.Name("x-forwarded-host")!],
                peerIsLoopback: WebAuthGuard.isLoopbackPeer(context.remoteAddress))
            let auth = WebAuthGuard.authorize(
                remoteAddress: context.remoteAddress,
                cookieHeader: request.headers[.cookie],
                forwardedFor: request.headers[HTTPField.Name("x-forwarded-for")!],
                forwardedProto: request.headers[HTTPField.Name("x-forwarded-proto")!],
                configProvider: { ConfigStore.loadConfig(devRoot: devRoot) },
                sessions: sessions)
            return (originOK && auth.isAuthorized) ? .upgrade() : .dontUpgrade
        } onUpgrade: { inbound, outbound, wsContext in
            // Captured at upgrade: first-run `run-setup` is a write+re-exec and
            // must stay local-direct (loopback, no XFF) like SecretRoutes — on a
            // non-loopback bind with auth still inert, Origin alone isn't enough
            // (review Yellow / CROW-605).
            let localDirect = WebAuthGuard.isLocalDirect(
                remoteAddress: wsContext.requestContext.remoteAddress,
                forwardedFor: wsContext.request.headers[HTTPField.Name("x-forwarded-for")!])
            // One outbound channel per connection: RPC responses (from the
            // reader task) and hub notifications (fanned in via `subscribe`)
            // both feed the single writer below.
            let (outStream, outCont) = AsyncStream.makeStream(of: String.self)
            let subscription = await eventHub.subscribe(outCont)

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Writer — the sole owner of `outbound`.
                group.addTask {
                    for await text in outStream {
                        try await outbound.write(.text(text))
                    }
                }
                // Reader — decode requests, dispatch, enqueue responses.
                group.addTask {
                    let decoder = JSONDecoder()
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    for try await message in inbound.messages(maxSize: 1 << 20) {
                        let payload: Data?
                        switch message {
                        case .text(let text): payload = text.data(using: .utf8)
                        case .binary(let buffer): payload = Data(buffer.readableBytesView)
                        }
                        guard let data = payload,
                              let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
                            continue
                        }
                        let response: JSONRPCResponse
                        if !localDirect, let deny = Self.localOnlyDenial(for: request, devRoot: devRoot) {
                            response = .error(
                                id: request.id,
                                code: RPCErrorCode.invalidParams,
                                message: deny)
                        } else {
                            response = await commandRouter.handle(request: request)
                        }
                        if let out = try? encoder.encode(response), let text = String(data: out, encoding: .utf8) {
                            outCont.yield(text)
                        }
                    }
                    // Inbound closed → end the writer so the group can unwind.
                    outCont.finish()
                }

                // When either side finishes (socket closed), tear the other down.
                _ = try? await group.next()
                group.cancelAll()
            }

            await eventHub.unsubscribe(subscription)
        }
    }

    /// Methods / fields that must stay local-direct (loopback, no XFF), matching
    /// `SecretRoutes` — the shared `CommandRouter` can't tell a local Unix-socket
    /// caller from a remote `/rpc` peer (review Yellow / CROW-593).
    ///
    /// - `run-setup`: write+re-exec of an arbitrary `dev_root`.
    /// - `set-config` when `defaults.binaries` or `jobs` change: those execute at
    ///   the next agent/job launch (persistent RCE on an unauthenticated
    ///   non-loopback bind). Other `set-config` fields still flow through.
    static func localOnlyDenial(for request: JSONRPCRequest, devRoot: String) -> String? {
        switch request.method {
        case "run-setup":
            return "run-setup is local-only"
        case "set-config":
            guard setConfigTouchesPrivilegedFields(request, devRoot: devRoot) else { return nil }
            return "set-config binaries/jobs is local-only"
        default:
            return nil
        }
    }

    /// True when the incoming `set-config` payload would change agent binary
    /// overrides or scheduled jobs relative to what's on disk.
    static func setConfigTouchesPrivilegedFields(_ request: JSONRPCRequest, devRoot: String) -> Bool {
        guard let json = request.params?["config"]?.stringValue,
              let data = json.data(using: .utf8),
              let incoming = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            // Malformed — let the real handler return invalidParams.
            return false
        }
        let current = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
        return incoming.defaults.binaries != current.defaults.binaries
            || incoming.jobs != current.jobs
    }
}
