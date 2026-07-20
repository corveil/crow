import Foundation
import Testing
import CrowCore
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

    // MARK: - Automation notifications (CROW-768)

    /// Decode a frame back into its parts so the assertions don't depend on key
    /// ordering, which `JSONEncoder` doesn't guarantee.
    private func decode(_ text: String) throws -> (method: String, params: [String: String]) {
        let object = try JSONSerialization.jsonObject(
            with: Data(text.utf8)) as? [String: Any]
        let params = (object?["params"] as? [String: Any])?
            .compactMapValues { $0 as? String } ?? [:]
        return ((object?["method"] as? String) ?? "", params)
    }

    @Test func notifyFrameIsAnIdlessNotificationCarryingTheEvent() throws {
        let text = EventHub.notifyFrame(
            event: .autoMergeEnabled, key: "session-id",
            title: "Auto-merge enabled — feature", body: "PR #12 will merge.")
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        // No `id`: clients that don't know the method can't correlate it and drop it.
        #expect(object?["id"] == nil)
        #expect(object?["jsonrpc"] as? String == "2.0")

        let (method, params) = try decode(text)
        #expect(method == "notify")
        #expect(params["event"] == "autoMergeEnabled")
        #expect(params["key"] == "session-id")
        #expect(params["title"] == "Auto-merge enabled — feature")
        #expect(params["body"] == "PR #12 will merge.")
    }

    @Test func notifyFrameEscapesQuotesAndBackslashes() throws {
        // Titles/bodies embed issue titles and session names — user-controlled
        // text that must not be able to produce a malformed frame.
        let nasty = #"a "quoted" \ back\slash"#
        let text = EventHub.notifyFrame(
            event: .autoWorkspaceCreated, key: "https://example.com/issues/1",
            title: nasty, body: nasty)
        let (method, params) = try decode(text)
        #expect(method == "notify")
        #expect(params["title"] == nasty)
        #expect(params["body"] == nasty)
    }

    @Test func broadcastNotificationReachesSubscribers() async throws {
        let hub = EventHub()
        let (stream, cont) = AsyncStream.makeStream(of: String.self)
        _ = await hub.subscribe(cont)
        await hub.broadcastNotification(
            event: .autoRebaseConflicts, key: "s1", title: "Rebase conflicts", body: "PR #3")

        var it = stream.makeAsyncIterator()
        let received = try #require(await it.next())
        let (method, params) = try decode(received)
        #expect(method == "notify")
        #expect(params["event"] == "autoRebaseConflicts")
        #expect(params["key"] == "s1")
        #expect(params["title"] == "Rebase conflicts")
        #expect(params["body"] == "PR #3")
    }
}
