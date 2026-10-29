import Foundation
import Testing
@testable import CabooseKit

/// The socket side of a GPU stream and the device's one-stream-at-a-time line
/// (docs/gpu-stream.md).
@Suite struct GPUStreamTests {
    /// Records deliveries, and how many were in progress at once.
    final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var inProgress = 0
        private(set) var chunks: [Data] = []
        private(set) var mostAtOnce = 0

        func enter(_ data: Data) {
            lock.withLock {
                chunks.append(data)
                inProgress += 1
                mostAtOnce = max(mostAtOnce, inProgress)
            }
        }

        func leave() { lock.withLock { inProgress -= 1 } }
        var snapshot: [Data] { lock.withLock { chunks } }
        var most: Int { lock.withLock { mostAtOnce } }
    }

    /// Bytes that arrive on the socket while the replay is still being handed earlier ones
    /// queue behind them: nothing overtakes, and the sink never runs twice at once.
    @Test func bytesArrivingDuringADeliveryWaitTheirTurn() {
        let feed = GPUStreamFeed()
        feed.receive(offset: 0, data: Data([1]))
        let deliveries = Deliveries()
        let inFirst = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let attached = DispatchSemaphore(value: 0)
        Thread {
            feed.attach { data in
                deliveries.enter(data)
                if data == Data([1]) {
                    inFirst.signal()
                    release.wait()
                }
                deliveries.leave()
            }
            attached.signal()
        }.start()
        #expect(inFirst.wait(timeout: .now() + 5) == .success)
        // The first chunk is being delivered and holds the sink: this one only queues.
        feed.receive(offset: 1, data: Data([2]))
        #expect(deliveries.snapshot == [Data([1])])
        release.signal()
        #expect(attached.wait(timeout: .now() + 5) == .success)
        #expect(deliveries.snapshot == [Data([1]), Data([2])])
        #expect(deliveries.most == 1)
        // Once idle, the next chunk is delivered by whoever brings it.
        feed.receive(offset: 2, data: Data([3]))
        #expect(deliveries.snapshot == [Data([1]), Data([2]), Data([3])])
        feed.detach()
    }

    @Test @MainActor func aSecondStreamWaitsForTheFirstAndThenPlays() {
        let first = RemoteGPUStream(id: 1, window: 7, feed: GPUStreamFeed()) { _ in }
        let second = RemoteGPUStream(id: 2, window: 9, feed: GPUStreamFeed()) { _ in }
        #expect(first.status == .playing)
        #expect(second.status == .waiting(behind: 7))
        #expect(RemoteGPUStream.message(for: second.status) != nil)
        first.end()
        #expect(second.status == .playing)
        #expect(RemoteGPUStream.message(for: second.status) == nil)
        second.end(reason: "spool-limit")
        #expect(second.status == .ended(reason: "spool-limit"))
        #expect(RemoteGPUStream.message(for: second.status)?.contains("keeps") == true)
        // Ending again changes nothing.
        second.end()
        #expect(second.status == .ended(reason: "spool-limit"))
    }
}
