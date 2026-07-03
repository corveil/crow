import CrowIPC
import Foundation
import Hummingbird
import HummingbirdWebSocket

/// Serves the existing JSON-RPC protocol over a WebSocket at `/rpc`.
///
/// One JSON object per WebSocket message: decode a ``JSONRPCRequest``, run it
/// through the shared ``CommandRouter`` (the very same router the Unix-socket
/// server uses), and write the ``JSONRPCResponse`` back. No semaphore bridge —
/// unlike `SocketServer`, we're already in an async context (CROW-581).
enum RPCWebSocketHandler {
    static func mount(on router: Router<BasicWebSocketRequestContext>, commandRouter: CommandRouter) {
        router.ws("/rpc") { _, _ in
            .upgrade()
        } onUpgrade: { inbound, outbound, _ in
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
                    try await outbound.write(.text(text))
                }
            }
        }
    }
}
