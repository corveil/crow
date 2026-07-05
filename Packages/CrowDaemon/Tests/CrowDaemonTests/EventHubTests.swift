import Foundation
import Testing
@testable import CrowDaemon

/// The fan-in broadcast hub behind `/rpc` server-push notifications (CROW-581,
/// M-D): subscribers receive every `broadcast`, and unsubscribing stops
/// delivery. Each subscriber owns its stream; the hub only yields into it.
@Suite struct EventHubTests {
    @Test func broadcastReachesAllSubscribers() async {
        let hub = EventHub()
        let (streamA, contA) = AsyncStream.makeStream(of: String.self)
        let (streamB, contB) = AsyncStream.makeStream(of: String.self)
        _ = await hub.subscribe(contA)
        _ = await hub.subscribe(contB)
        #expect(await hub.subscriberCount == 2)

        await hub.broadcast("hello")
        var itA = streamA.makeAsyncIterator()
        var itB = streamB.makeAsyncIterator()
        #expect(await itA.next() == "hello")
        #expect(await itB.next() == "hello")
    }

    @Test func unsubscribeStopsDelivery() async {
        let hub = EventHub()
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        let id = await hub.subscribe(cont)
        await hub.unsubscribe(id)
        #expect(await hub.subscriberCount == 0)

        // After unsubscribe the stream receives nothing more; finishing it lets
        // the iterator terminate rather than hang.
        await hub.broadcast("dropped")
        cont.finish()
        var it = stream.makeAsyncIterator()
        #expect(await it.next() == nil)
    }

    @Test func defaultFrameIsAnIdlessChangedNotification() async {
        // Older clients ignore it (no `id` to correlate) — safe to broadcast.
        #expect(EventHub.changedFrame == #"{"jsonrpc":"2.0","method":"changed"}"#)
    }
}
