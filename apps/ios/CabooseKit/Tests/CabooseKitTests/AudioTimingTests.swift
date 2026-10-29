import Foundation
import Testing
@testable import CabooseKit

@Suite struct AudioTimingTests {
    @Test func aggregatesStagesAndKeepsGapsAcrossReportBoundaries() {
        var timing = AudioTimingAccumulator()
        timing.receive(at: 10, incoming: 11)
        timing.finishIncoming(start: 11, end: 13)
        timing.packet(received: 10, dispatched: 13, entered: 17, decoded: 22,
                      enqueueStarted: 28, enqueued: 35, finished: 36)
        let first = timing.takeInterval()
        #expect(first.receipts == 1 && first.packets == 1)
        #expect(first.incomingWait == 1 && first.incomingWork == 2)
        #expect(first.receiptToDispatch == 3 && first.queueWait == 4)
        #expect(first.decode == 5 && first.prepare == 6 && first.enqueue == 7)
        #expect(first.total == 26 && first.receiptGap == 0)
        #expect(timing.takeInterval() == AudioTimingInterval())

        timing.receive(at: 50, incoming: 50)
        timing.finishIncoming(start: 50, end: 51)
        timing.packet(received: 50, dispatched: 51, entered: 52, decoded: 53,
                      enqueueStarted: 54, enqueued: 55, finished: 56)
        timing.receive(at: 60, incoming: 60)
        timing.packet(received: 60, dispatched: 61, entered: 62, decoded: 63,
                      enqueueStarted: 64, enqueued: 65, finished: 66)
        let second = timing.takeInterval()
        #expect(second.receipts == 2 && second.packets == 2)
        #expect(second.receiptGap == 40 && second.audioReceiptGap == 40)
        #expect(second.dispatchGap == 38 && second.queueEntryGap == 35)
        #expect(second.decodeCompletionGap == 31 && second.enqueueCompletionGap == 20)
        #expect(second.queueWait == 1 && second.decode == 1 && second.enqueue == 1)
    }

    @Test func resetDiscardsIdleTimeAndPreviousMaxima() {
        var timing = AudioTimingAccumulator()
        timing.receive(at: 1, incoming: 2)
        timing.packet(received: 1, dispatched: 3, entered: 4, decoded: 5,
                      enqueueStarted: 6, enqueued: 7, finished: 8)
        timing.reset()
        timing.receive(at: 100, incoming: 100)
        timing.packet(received: 100, dispatched: 100, entered: 100, decoded: 100,
                      enqueueStarted: 100, enqueued: 100, finished: 100)
        var expected = AudioTimingInterval()
        expected.receipts = 1; expected.packets = 1
        #expect(timing.takeInterval() == expected)
    }

    @Test func failedDecodeStillRecordsQueueWaitWithoutInventingCompletion() {
        var timing = AudioTimingAccumulator()
        timing.packet(received: 1, dispatched: 2, entered: 5, decoded: nil,
                      enqueueStarted: nil, enqueued: nil, finished: 7)
        let result = timing.takeInterval()
        #expect(result.packets == 1 && result.queueWait == 3 && result.total == 6)
        #expect(result.decode == 0 && result.enqueue == 0 && result.enqueueCompletionGap == 0)
    }

    @Test func durationsAreNonnegativeAndRejectNonfiniteClocks() {
        #expect(AudioTimingAccumulator.elapsed(1, since: 2) == 0)
        #expect(AudioTimingAccumulator.elapsed(.infinity, since: 2) == 0)
        #expect(AudioTimingAccumulator.elapsed(1, since: .nan) == 0)
        var timing = AudioTimingAccumulator()
        timing.receive(at: 10, incoming: 9)
        timing.finishIncoming(start: 9, end: 8)
        timing.packet(received: 10, dispatched: 9, entered: 8, decoded: 7,
                      enqueueStarted: 6, enqueued: 5, finished: 4)
        var expected = AudioTimingInterval()
        expected.receipts = 1; expected.packets = 1
        #expect(timing.takeInterval() == expected)
    }
}
