import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Request contexts that expose the connected peer's address, so `WebAuthGuard`
/// can distinguish a loopback client from a proxied/remote one (CROW-593). These
/// mirror Hummingbird's `BasicRequestContext` / `BasicWebSocketRequestContext`
/// exactly, plus a `remoteAddress` derived from the channel (the standard
/// `RemoteAddressRequestContext` pattern).

/// HTTP request context with peer address.
struct CrowHTTPContext: RequestContext, RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }
}

/// WebSocket request context with peer address.
struct CrowWSContext: WebSocketRequestContext, RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let webSocket: WebSocketHandlerReference<CrowWSContext>
    let remoteAddress: SocketAddress?

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.webSocket = .init()
        self.remoteAddress = source.channel.remoteAddress
    }
}
