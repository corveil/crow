import CrowIPC
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
        on router: Router<BasicWebSocketRequestContext>,
        commandRouter: CommandRouter,
        eventHub: EventHub,
        boundHost: String
    ) {
        router.ws("/rpc") { request, _ in
            // Reject cross-site upgrades — `/rpc` reaches `add-worktree`, which
            // shells out to git (CROW-581 review).
            WebSocketOriginGuard.isAllowedOrigin(request.headers[.origin], boundHost: boundHost)
                ? .upgrade() : .dontUpgrade
        } onUpgrade: { inbound, outbound, _ in
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
                        let response = await commandRouter.handle(request: request)
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
}
