import Foundation
import Testing
import CrowCore
import CrowEngine
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// The kickoff chain must run enqueued ops in order, each awaiting its
/// predecessor — that's what keeps `createReviewSession`'s dedupe race-free
/// under concurrent `start-review` (CROW-581, M-E2). A kickoff that never
/// returns must not pin the chain (CROW-1323).
@Suite(.serialized) struct ReviewKickoffSerializerTests {
    private actor Recorder {
        var order: [Int] = []
        func add(_ n: Int) { order.append(n) }
    }

    @Test func kickoffsRunInEnqueueOrderEvenIfLaterOnesAreFaster() async {
        let serializer = ReviewKickoffSerializer()
        let recorder = Recorder()

        // First op sleeps; a naive (unserialized) run would let the second
        // finish first. Serialization forces 1 before 2.
        let t1 = await serializer.enqueue {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await recorder.add(1)
            return nil
        }
        let t2 = await serializer.enqueue {
            await recorder.add(2)
            return nil
        }
        _ = await t1.value
        _ = await t2.value

        #expect(await recorder.order == [1, 2])
    }

    /// A kickoff that never returns used to pin every later review for the
    /// life of the daemon. The chain must advance when the timeout fires,
    /// and the line must land in the automation log.
    @Test(.timeLimit(.minutes(1)))
    func kickoffThatNeverCompletesDoesNotBlockTheNext() async throws {
        let timeout: Duration = .milliseconds(200)
        let serializer = ReviewKickoffSerializer(timeout: timeout)
        let recorder = Recorder()
        let url = "https://github.com/corveil/crow/pull/1323"

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1323-kickoff-\(UUID().uuidString)", isDirectory: true)
        CrowLog.configure(directory: dir)
        defer {
            CrowLog.flush(timeout: 5)
            CrowLog.configure(directory: nil)
            try? FileManager.default.removeItem(at: dir)
        }

        let started = ContinuousClock.now
        // Parks until the test releases it, so the hang ignores cancellation
        // without leaking a continuation when the function returns.
        let parking = ParkingLot()
        defer { parking.unpark() }
        let hung = await serializer.enqueue(url: url) {
            await parking.park()
            return nil
        }
        let next = await serializer.enqueue(url: "https://github.com/corveil/crow/pull/2") {
            await recorder.add(2)
            return UUID()
        }
        let hungResult = await hung.value
        let nextResult = await next.value
        let elapsed = ContinuousClock.now - started

        #expect(hungResult == nil)
        #expect(nextResult != nil)
        #expect(await recorder.order == [2])
        #expect(elapsed < .seconds(5))

        #expect(CrowLog.flush(timeout: 5))
        let log = try String(contentsOf: dir.appendingPathComponent("crowd-automation.log"), encoding: .utf8)
        #expect(log.contains("[ReviewKickoff] timed out after \(ReviewKickoffSerializer.phrase(timeout)) for \(url)"))
    }

    @Test func failedKickoffClearsTheFingerprintSoTheSameHeadRetries() async {
        let serializer = ReviewKickoffSerializer(timeout: .seconds(5))
        let queue = AutoReviewKickoffQueue(serializer: serializer)
        let attempts = Attempts()
        let request = Self.makeRequest(head: "abc")

        queue.schedule(requests: [request], patterns: ["corveil/*"]) { _ in
            await attempts.bump()
            return nil
        }
        #expect(await Self.waitUntil { await attempts.value == 1 && !queue.contains(requestID: request.id, head: "abc") })

        queue.schedule(requests: [request], patterns: ["corveil/*"]) { _ in
            await attempts.bump()
            return UUID()
        }
        #expect(await Self.waitUntil { await attempts.value == 2 && queue.contains(requestID: request.id, head: "abc") })

        queue.schedule(requests: [request], patterns: ["corveil/*"]) { _ in
            await attempts.bump()
            return UUID()
        }
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await attempts.value == 2)
    }

    /// The auto watcher and `start-review` are given one serializer by
    /// `CrowDaemon.run`. Each path has to actually enqueue on that object:
    /// a second `ReviewKickoffSerializer()` in either call site is what let
    /// a manual start keep working while the auto chain was dead.
    @Test(.timeLimit(.minutes(1))) @MainActor
    func autoAndRPCPathsResolveToTheSameSerializerInstance() async throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CrowDaemon/CrowDaemon.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(source.components(separatedBy: "ReviewKickoffSerializer()").count - 1 == 1)
        #expect(source.components(separatedBy: "reviewSerializer: reviewSerializer").count - 1 == 2)

        let shared = ReviewKickoffSerializer(timeout: .seconds(5))
        let queue = AutoReviewKickoffQueue(serializer: shared)
        #expect(queue.serializer === shared)

        let appState = AppState()
        let store = JSONStore.temporary()
        let service = SessionService(store: store, appState: appState)
        let router = makeCommandRouter(
            appState: appState,
            store: store,
            git: GitManager(),
            devRoot: NSTemporaryDirectory(),
            cockpit: nil,
            sessionService: service,
            reviewSerializer: shared)

        let gate = Gate()
        let blocker = await shared.enqueue(url: "https://example.com/hold") {
            await gate.wait()
            return nil
        }

        let request = Self.makeRequest(head: "deadbeef")
        let autoAttempts = Attempts()
        queue.schedule(requests: [request], patterns: ["corveil/*"]) { _ in
            await autoAttempts.bump()
            return nil
        }

        let rpcFinished = Flag()
        let rpcTask = Task {
            _ = await router.handle(request: JSONRPCRequest(
                id: 1,
                method: "start-review",
                params: ["url": .string("https://github.com/corveil/crow/pull/1")]))
            rpcFinished.set()
        }

        try await Task.sleep(for: .milliseconds(300))
        #expect(await autoAttempts.value == 0)
        #expect(rpcFinished.get() == false)
        #expect(queue.contains(requestID: request.id, head: "deadbeef"))

        gate.open()
        _ = await blocker.value
        _ = await rpcTask.value
        // Poll here instead of `waitUntil`. This test is `@MainActor`, and
        // sending its closure into the nonisolated helper is a data race.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline, await autoAttempts.value != 1 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await autoAttempts.value == 1)
        #expect(rpcFinished.get())
    }

    private static func makeRequest(head: String) -> ReviewRequest {
        ReviewRequest(
            id: "github:corveil/crow#1",
            prNumber: 1,
            title: "kickoff",
            url: "https://github.com/corveil/crow/pull/1",
            repo: "corveil/crow",
            author: "ada",
            headBranch: "feature",
            baseBranch: "main",
            headRefOid: head)
    }

    private static func waitUntil(timeout: Duration = .seconds(3), _ body: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await body() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await body()
    }
}

private actor Attempts {
    private(set) var value = 0
    func bump() { value += 1 }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// A continuation the serializer's operation parks on. `unpark` resumes it
/// so the test process does not report a leaked continuation.
private final class ParkingLot: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func park() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func unpark() {
        lock.lock()
        released = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}
