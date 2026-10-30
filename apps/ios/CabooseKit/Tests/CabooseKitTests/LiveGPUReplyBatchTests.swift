import Foundation
import XCTest
@testable import CabooseKit

final class LiveGPUReplyBatchTests: XCTestCase {
    private let executor = Data((1...16).map(UInt8.init))
    private let generation: UInt64 = 9

    private func replyEnvelope(sequence: UInt64, process: UInt64, stream: UInt64, payload: Data) throws -> Data {
        try LiveGPUEnvelope(
            kind: .data,
            executor: executor,
            generation: generation,
            process: process,
            stream: stream,
            sequence: sequence,
            payload: payload
        ).encoded()
    }

    func testFirstSendIsImmediateAndSubsequentReadyRepliesCoalesceAcrossStreamsInFIFOOrder() throws {
        let budget = LiveGPUBudget()
        let queue = LiveGPUOutboundQueue(budget: budget)

        let first = try replyEnvelope(sequence: 1, process: 1, stream: 1, payload: Data([0, 0, 0, 0]))
        XCTAssertNil(budget.admit(first.count))
        queue.enqueue(first)

        // First send starts immediately with zero scratch overhead.
        guard let firstBatch = queue.nextBatch() else { return XCTFail("expected immediate first batch") }
        XCTAssertEqual(firstBatch.data, first)
        XCTAssertEqual(firstBatch.count, 1)
        XCTAssertEqual(firstBatch.originalBytes, first.count)
        XCTAssertEqual(firstBatch.scratchBytes, 0)
        XCTAssertEqual(budget.retained.bytes, first.count)
        XCTAssertEqual(budget.retained.count, 1)
        XCTAssertNil(queue.nextBatch())

        // While the first send is in flight, 8 window replies arrive across multiple streams.
        var queuedEnvelopes: [Data] = []
        for index in 0..<8 {
            let seq = UInt64(index + 2)
            let stream = UInt64((index % 3) + 1)
            let payload = Data([UInt8(index), 0, 0, 0])
            let wire = try replyEnvelope(sequence: seq, process: 1, stream: stream, payload: payload)
            XCTAssertNil(budget.admit(wire.count))
            queue.enqueue(wire)
            queuedEnvelopes.append(wire)
        }
        let queuedBytes = queuedEnvelopes.reduce(0) { $0 + $1.count }
        XCTAssertEqual(budget.retained.bytes, first.count + queuedBytes)
        XCTAssertEqual(budget.retained.count, 9)

        // Complete first send; nextBatch coalesces all 8 ready replies and reserves scratch.
        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, queuedBytes)
        XCTAssertEqual(budget.retained.count, 8)

        guard let coalesced = queue.nextBatch() else { return XCTFail("expected coalesced batch") }
        XCTAssertEqual(coalesced.count, 8)
        XCTAssertEqual(coalesced.originalBytes, queuedBytes)
        XCTAssertEqual(coalesced.scratchBytes, queuedBytes)
        XCTAssertEqual(coalesced.data.count, queuedBytes)
        // Both original permits and destination scratch are retained while in flight.
        XCTAssertEqual(budget.retained.bytes, 2 * queuedBytes)
        XCTAssertEqual(budget.retained.count, 8)

        // Streaming CGLV decoder decodes the exact sequence and stream order from the single frame.
        let decoder = try LiveGPUEnvelopeDecoder(executor: executor, generation: generation)
        var decoded: [LiveGPUEnvelope] = []
        try decoder.feed(firstBatch.data) { decoded.append($0) }
        try decoder.feed(coalesced.data) { decoded.append($0) }
        try decoder.finish()
        XCTAssertEqual(decoded.map(\.sequence), Array(1...9).map(UInt64.init))
        XCTAssertEqual(decoded.dropFirst().map(\.stream), (0..<8).map { UInt64(($0 % 3) + 1) })
        XCTAssertEqual(decoded.dropFirst().map { Array($0.payload) }, (0..<8).map { [UInt8($0), 0, 0, 0] })

        XCTAssertTrue(queue.completeInFlight())
        XCTAssertFalse(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 0)
    }

    func testMessageByteLimitAndCountCapBoundCoalescedPrefix() throws {
        let budget = LiveGPUBudget()
        let queue = LiveGPUOutboundQueue(budget: budget)

        // 5 messages of 60 KiB each: total 300 KiB > 256 KiB messageLimit, so at most 4 coalesce (240 KiB).
        let chunk = Data(repeating: 0x5a, count: 60 * 1024)
        for _ in 0..<5 {
            XCTAssertNil(budget.admit(chunk.count))
            queue.enqueue(chunk)
        }
        guard let batch1 = queue.nextBatch() else { return XCTFail("expected first bounded batch") }
        XCTAssertEqual(batch1.count, 4)
        XCTAssertEqual(batch1.originalBytes, 240 * 1024)
        XCTAssertEqual(batch1.scratchBytes, 240 * 1024)
        XCTAssertEqual(budget.retained.bytes, 5 * 60 * 1024 + 240 * 1024)
        XCTAssertEqual(budget.retained.count, 5)
        XCTAssertEqual(queue.pendingCount, 1)

        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 60 * 1024)
        XCTAssertEqual(budget.retained.count, 1)

        guard let batch2 = queue.nextBatch() else { return XCTFail("expected remainder batch") }
        XCTAssertEqual(batch2.count, 1)
        XCTAssertEqual(batch2.scratchBytes, 0)
        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 0)

        // 64 messages of 10 bytes each: all 64 coalesce into one 640-byte frame (+ 640 scratch).
        for i in 0..<LiveGPUBudget.countLimit {
            let small = Data(repeating: UInt8(i), count: 10)
            XCTAssertNil(budget.admit(small.count))
            queue.enqueue(small)
        }
        guard let fullCountBatch = queue.nextBatch() else { return XCTFail("expected 64-record batch") }
        XCTAssertEqual(fullCountBatch.count, LiveGPUBudget.countLimit)
        XCTAssertEqual(fullCountBatch.originalBytes, 640)
        XCTAssertEqual(fullCountBatch.scratchBytes, 640)
        XCTAssertEqual(budget.retained.bytes, 1280)
        XCTAssertEqual(budget.retained.count, LiveGPUBudget.countLimit)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 0)
    }

    func testScratchPressureFallsBackToUncoalescedSendWithoutRevokingBudget() {
        let budget = LiveGPUBudget()
        let queue = LiveGPUOutboundQueue(budget: budget)

        // Admit 9 items of 100 KiB = 900 KiB. Two items (200 KiB <= 256 KiB messageLimit)
        // can coalesce, but 200 KiB scratch exceeds remaining 124 KiB headroom (1024 KiB - 900 KiB).
        let item = Data(repeating: 0x33, count: 100 * 1024)
        for _ in 0..<9 {
            XCTAssertNil(budget.admit(item.count))
            queue.enqueue(item)
        }
        guard let fallback = queue.nextBatch() else { return XCTFail("expected uncoalesced fallback") }
        XCTAssertTrue(budget.active)
        XCTAssertEqual(fallback.count, 1)
        XCTAssertEqual(fallback.originalBytes, 100 * 1024)
        XCTAssertEqual(fallback.scratchBytes, 0)
        XCTAssertEqual(budget.retained.bytes, 900 * 1024)
        XCTAssertEqual(budget.retained.count, 9)

        // Completing the first 100 KiB uncoalesced send leaves 800 KiB retained (224 KiB headroom),
        // which immediately fits a 2-item (200 KiB) coalesced batch + 200 KiB scratch = 1000 KiB <= 1024 KiB.
        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 800 * 1024)
        XCTAssertEqual(budget.retained.count, 8)

        guard let coalesced = queue.nextBatch() else { return XCTFail("expected coalesced batch after first send freed headroom") }
        XCTAssertTrue(budget.active)
        XCTAssertEqual(coalesced.count, 2)
        XCTAssertEqual(coalesced.originalBytes, 200 * 1024)
        XCTAssertEqual(coalesced.scratchBytes, 200 * 1024)
        XCTAssertEqual(budget.retained.bytes, 800 * 1024 + 200 * 1024)
        XCTAssertEqual(budget.retained.count, 8)
        XCTAssertEqual(queue.pendingCount, 6)

        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 600 * 1024)
        XCTAssertEqual(budget.retained.count, 6)

        while let rest = queue.nextBatch() {
            XCTAssertTrue(rest.count >= 1)
            XCTAssertTrue(queue.completeInFlight())
        }
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 0)
    }

    func testEmptyAndMixedEmptyRecordsAlwaysConsumePrefixWithoutDoubleRelease() {
        let budget = LiveGPUBudget()
        let queue = LiveGPUOutboundQueue(budget: budget)

        // Two empty Data records: total == 0, nil-backed Data(count: 0) must still remove all
        // coalesced pending entries so completeInFlight() + discardPending() never double-release.
        for _ in 0..<2 {
            XCTAssertNil(budget.admit(0))
            queue.enqueue(Data())
        }
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 2)
        guard let emptyBatch = queue.nextBatch() else { return XCTFail("expected coalesced empty batch") }
        XCTAssertEqual(emptyBatch.count, 2)
        XCTAssertEqual(emptyBatch.originalBytes, 0)
        XCTAssertEqual(emptyBatch.scratchBytes, 0)
        XCTAssertTrue(emptyBatch.data.isEmpty)
        XCTAssertTrue(queue.isEmpty)
        queue.discardPending()
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 2)
        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 0)

        // Mixed empty and non-empty records preserve exact byte order and count accounting.
        let records = [Data(), Data([1, 2]), Data(), Data([3, 4, 5]), Data()]
        for record in records {
            XCTAssertNil(budget.admit(record.count))
            queue.enqueue(record)
        }
        XCTAssertEqual(budget.retained.bytes, 5)
        XCTAssertEqual(budget.retained.count, 5)
        guard let mixedBatch = queue.nextBatch() else { return XCTFail("expected coalesced mixed batch") }
        XCTAssertEqual(mixedBatch.count, 5)
        XCTAssertEqual(mixedBatch.originalBytes, 5)
        XCTAssertEqual(mixedBatch.scratchBytes, 5)
        XCTAssertEqual(mixedBatch.data, Data([1, 2, 3, 4, 5]))
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(budget.retained.bytes, 10)
        XCTAssertEqual(budget.retained.count, 5)
        queue.discardPending()
        XCTAssertTrue(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 0)
    }

    func testCloseWithPendingAndInFlightBatchReleasesPendingImmediatelyAndInFlightOnCallback() {
        let budget = LiveGPUBudget()
        let queue = LiveGPUOutboundQueue(budget: budget)

        for i in 1...5 {
            let data = Data(repeating: UInt8(i), count: 100)
            XCTAssertNil(budget.admit(data.count))
            queue.enqueue(data)
        }
        // Start a 5-item coalesced batch (500 original + 500 scratch = 1000 bytes, count = 5).
        guard let inFlight = queue.nextBatch() else { return XCTFail("expected coalesced batch") }
        XCTAssertEqual(inFlight.count, 5)
        XCTAssertEqual(budget.retained.bytes, 1000)
        XCTAssertEqual(budget.retained.count, 5)

        // Queue 3 more items (300 bytes, count +3) while first batch is in flight.
        for i in 6...8 {
            let data = Data(repeating: UInt8(i), count: 100)
            XCTAssertNil(budget.admit(data.count))
            queue.enqueue(data)
        }
        XCTAssertEqual(budget.retained.bytes, 1300)
        XCTAssertEqual(budget.retained.count, 8)

        // Simulate close() / completion error: revoke budget and discardPending().
        budget.revoke()
        queue.discardPending()
        queue.discardPending() // idempotent
        // Pending 300 bytes / 3 count are released; in-flight 1000 bytes / 5 count remain until callback.
        XCTAssertEqual(budget.retained.bytes, 1000)
        XCTAssertEqual(budget.retained.count, 5)
        XCTAssertNil(queue.nextBatch())

        // Late send completion callback releases the in-flight batch plus scratch exactly once.
        XCTAssertTrue(queue.completeInFlight())
        XCTAssertFalse(queue.completeInFlight())
        XCTAssertEqual(budget.retained.bytes, 0)
        XCTAssertEqual(budget.retained.count, 0)
    }
}
