import Foundation
import Testing
@testable import CrowDaemon

/// The kickoff chain must run enqueued ops in order, each awaiting its
/// predecessor — that's what keeps `createReviewSession`'s dedupe race-free
/// under concurrent `start-review` (CROW-581, M-E2).
@Suite struct ReviewKickoffSerializerTests {
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
}
