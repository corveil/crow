import CrowIPC
import Foundation
import Testing
@testable import CrowDaemon

/// The `/rpc` read loop hands every request to ``RPCDispatcher`` instead of
/// awaiting it inline (#931). These pin the four properties that makes safe:
/// unrelated requests overtake a slow one, same-lane requests never do, the pool
/// is bounded, and nothing is lost or left parked at teardown.
@Suite struct RPCDispatcherTests {

    private actor Recorder {
        var order: [String] = []
        func add(_ s: String) { order.append(s) }
    }

    /// Counts concurrent operations and remembers the high-water mark.
    private actor Peak {
        private var current = 0
        private(set) var peak = 0
        func enter() { current += 1; peak = max(peak, current) }
        func leave() { current -= 1 }
    }

    /// Parks operations until opened, so a test can hold work in flight.
    private actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let w = waiters
            waiters.removeAll()
            w.forEach { $0.resume() }
        }
    }

    // MARK: - The bug

    @Test func aSlowLaneDoesNotDelayAnotherLane() async {
        let dispatcher = RPCDispatcher()
        let recorder = Recorder()

        await dispatcher.dispatch(lane: .param(name: "session_id", value: "A")) {
            try? await Task.sleep(nanoseconds: 60_000_000)
            await recorder.add("slow")
        }
        await dispatcher.dispatch(lane: .param(name: "session_id", value: "B")) {
            await recorder.add("fast")
        }
        await dispatcher.drain()

        // Inline dispatch — the #931 shape — would give ["slow", "fast"].
        #expect(await recorder.order == ["fast", "slow"])
    }

    @Test func aLanelessRequestOvertakesASlowLane() async {
        let dispatcher = RPCDispatcher()
        let recorder = Recorder()

        await dispatcher.dispatch(lane: .config) {
            try? await Task.sleep(nanoseconds: 60_000_000)
            await recorder.add("config")
        }
        await dispatcher.dispatch(lane: nil) { await recorder.add("read") }
        await dispatcher.drain()

        #expect(await recorder.order == ["read", "config"])
    }

    // MARK: - Ordering

    @Test func sameLaneRunsInArrivalOrderEvenWhenLaterOpsAreFaster() async {
        let dispatcher = RPCDispatcher()
        let recorder = Recorder()
        let lane = RPCDispatcher.Lane.param(name: "session_id", value: "S")

        // The set-status / complete-session pair from the issue.
        await dispatcher.dispatch(lane: lane) {
            try? await Task.sleep(nanoseconds: 40_000_000)
            await recorder.add("set-status")
        }
        await dispatcher.dispatch(lane: lane) { await recorder.add("complete-session") }
        await dispatcher.drain()

        #expect(await recorder.order == ["set-status", "complete-session"])
    }

    @Test func distinctParamNamesDoNotShareALane() async {
        // A session UUID and a terminal UUID can be equal strings; they must not
        // collide into one lane.
        let dispatcher = RPCDispatcher()
        let recorder = Recorder()
        let shared = UUID().uuidString

        await dispatcher.dispatch(lane: .param(name: "session_id", value: shared)) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await recorder.add("session")
        }
        await dispatcher.dispatch(lane: .param(name: "terminal_id", value: shared)) {
            await recorder.add("terminal")
        }
        await dispatcher.drain()

        #expect(await recorder.order == ["terminal", "session"])
    }

    // MARK: - Bounds

    @Test func neverRunsMoreThanTheConcurrencyCap() async {
        let dispatcher = RPCDispatcher(maxConcurrent: 3, maxInFlight: 64)
        let peak = Peak()
        for _ in 0..<24 {
            await dispatcher.dispatch(lane: nil) {
                await peak.enter()
                try? await Task.sleep(nanoseconds: 10_000_000)
                await peak.leave()
            }
        }
        await dispatcher.drain()
        #expect(await peak.peak <= 3)
        // …and it really is running them in parallel, not one at a time.
        #expect(await peak.peak > 1)
    }

    /// The deadlock this design is shaped to avoid: if a queued lane task took
    /// its permit *before* awaiting its predecessor, a burst deeper than the cap
    /// would hold every permit waiting on tasks that can never get one.
    @Test func aLaneBurstDeeperThanTheCapStillCompletesInOrder() async {
        let dispatcher = RPCDispatcher(maxConcurrent: 2, maxInFlight: 64)
        let recorder = Recorder()
        let lane = RPCDispatcher.Lane.param(name: "session_id", value: "S")

        for i in 0..<8 {
            await dispatcher.dispatch(lane: lane) {
                try? await Task.sleep(nanoseconds: 2_000_000)
                await recorder.add("\(i)")
            }
        }
        await dispatcher.drain()

        #expect(await recorder.order == (0..<8).map(String.init))
        #expect(await dispatcher.runningCount == 0)
    }

    /// And the same burst must not monopolise the pool: one lane holds at most
    /// one permit, so an unrelated request still gets through promptly.
    @Test func aLaneBurstDoesNotStarveOtherLanes() async {
        let dispatcher = RPCDispatcher(maxConcurrent: 2, maxInFlight: 64)
        let recorder = Recorder()
        let lane = RPCDispatcher.Lane.param(name: "session_id", value: "S")

        for _ in 0..<8 {
            await dispatcher.dispatch(lane: lane) {
                try? await Task.sleep(nanoseconds: 20_000_000)
                await recorder.add("burst")
            }
        }
        await dispatcher.dispatch(lane: nil) { await recorder.add("other") }
        await dispatcher.drain()

        // "other" lands well before the 8-deep chain finishes.
        #expect((await recorder.order.firstIndex(of: "other") ?? .max) < 4)
    }

    @Test func refusesBeyondTheInFlightCeiling() async {
        let dispatcher = RPCDispatcher(maxConcurrent: 8, maxInFlight: 2)
        let gate = Gate()

        #expect(await dispatcher.dispatch(lane: nil) { await gate.wait() })
        #expect(await dispatcher.dispatch(lane: nil) { await gate.wait() })
        // The third is refused, so the reader answers it itself rather than
        // letting it sit until the client's deadline.
        #expect(await dispatcher.dispatch(lane: nil) {} == false)

        await gate.open()
        await dispatcher.drain()
        // Capacity returns once the ceiling clears.
        #expect(await dispatcher.dispatch(lane: nil) {})
        await dispatcher.drain()
    }

    // MARK: - Lifecycle

    @Test func drainReturnsOnlyAfterEveryResponseIsYielded() async {
        let dispatcher = RPCDispatcher()
        let (stream, cont) = AsyncStream.makeStream(of: String.self)

        for i in 0..<5 {
            await dispatcher.dispatch(lane: nil) {
                try? await Task.sleep(nanoseconds: UInt64((5 - i) * 10_000_000))
                cont.yield("r\(i)")
            }
        }
        await dispatcher.drain()
        // Exactly what the reader does next: nothing may still be in flight.
        cont.finish()

        var received: [String] = []
        for await text in stream { received.append(text) }
        #expect(received.count == 5)
        #expect(Set(received) == Set((0..<5).map { "r\($0)" }))
    }

    @Test func shutdownReleasesADrainerAndSkipsQueuedWork() async {
        let dispatcher = RPCDispatcher(maxConcurrent: 1, maxInFlight: 64)
        let gate = Gate()
        let recorder = Recorder()
        let lane = RPCDispatcher.Lane.param(name: "session_id", value: "S")

        await dispatcher.dispatch(lane: lane) {
            await gate.wait()
            await recorder.add("running")
        }
        await dispatcher.dispatch(lane: lane) { await recorder.add("queued") }

        // The writer died: teardown shuts the dispatcher down, which must unpark
        // a reader sitting in drain() rather than hang the connection's group.
        let drained = Task { await dispatcher.drain() }
        await dispatcher.shutdown()
        await drained.value // returns without gate.open()

        await gate.open()
        // The queued operation was cancelled before it ever took a permit.
        #expect(await recorder.order.contains("queued") == false)
    }

    @Test func laneTailsAreEvictedSoTheMapCannotGrowWithSessionCount() async {
        let dispatcher = RPCDispatcher()
        for i in 0..<200 {
            await dispatcher.dispatch(lane: .param(name: "session_id", value: "s\(i)")) {}
        }
        await dispatcher.drain()
        #expect(await dispatcher.laneCount == 0)
        #expect(await dispatcher.inFlightCount == 0)
    }

    // MARK: - Through a real router

    /// The end-to-end shape of the fix without a socket: a slow method and a
    /// fast one on one `CommandRouter`, dispatched as the reader dispatches
    /// them. The fast reply must reach the stream first.
    @Test func aSlowHandlerDoesNotHoldUpAFastOneOnTheSameRouter() async {
        let router = CommandRouter(handlers: [
            "slow": { _ in
                try? await Task.sleep(nanoseconds: 60_000_000)
                return ["ok": .bool(true)]
            },
            "fast": { _ in ["ok": .bool(true)] },
        ])
        let dispatcher = RPCDispatcher()
        let recorder = Recorder()

        await dispatcher.dispatch(lane: nil) {
            let r = await router.handle(request: JSONRPCRequest(id: 1, method: "slow"))
            await recorder.add("\(r.id)")
        }
        await dispatcher.dispatch(lane: nil) {
            let r = await router.handle(request: JSONRPCRequest(id: 2, method: "fast"))
            await recorder.add("\(r.id)")
        }
        await dispatcher.drain()

        #expect(await recorder.order == ["2", "1"])
    }
}
