import Foundation
import Testing
@testable import CabooseKit

/// The socket side of GPU streams and their independent replay lifetimes
/// (docs/gpu-stream.md).
@Suite(.serialized) struct GPUStreamTests {
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
            feed.attach { _, data in
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

    /// A resumed stream's feed starts where the kept replay stands: bytes from before it are
    /// not taken again.
    @Test func aResumedFeedStartsAtItsOffset() {
        let feed = GPUStreamFeed(offset: 4)
        final class Received: @unchecked Sendable { var chunks: [Data] = [] }
        let received = Received()
        feed.attach { _, data in received.chunks.append(data) }
        feed.receive(offset: 0, data: Data([1, 2, 3, 4]))
        feed.receive(offset: 4, data: Data([5]))
        #expect(received.chunks == [Data([5])])
        #expect(feed.offset == 5)
        feed.detach()
    }

    /// A chunk that overlaps the next offset brings what follows it, and the sink hears each
    /// chunk's offset; a restart drops what is queued and takes the stream from a new offset.
    @Test func aFeedTakesOverlapsAndRestarts() {
        let feed = GPUStreamFeed()
        feed.receive(offset: 0, data: Data([1, 2, 3]))
        feed.receive(offset: 2, data: Data([3, 4, 5]))
        #expect(feed.offset == 5)
        feed.restart(at: 8)
        feed.receive(offset: 6, data: Data([7, 8, 9, 10]))
        feed.receive(offset: 12, data: Data([13]))
        final class Received: @unchecked Sendable { var chunks: [(offset: UInt64, data: Data)] = [] }
        let received = Received()
        feed.attach { offset, data in received.chunks.append((offset, data)) }
        #expect(received.chunks.map({ $0.offset }) == [8])
        #expect(received.chunks.map({ $0.data }) == [Data([9, 10])])
        #expect(feed.offset == 10)
        feed.receive(offset: 10, data: Data([11]))
        #expect(received.chunks.map({ $0.offset }) == [8, 10])
        feed.detach()
    }

    /// A new replay takes the stream's start from the device's copy when there is one, and asks
    /// the computer to go back only when it continues the stream elsewhere and there is none.
    @Test func aNewReplayStartsFromTheDevicesCopyWhenItHasOne() {
        typealias R = GPUStreamResume
        #expect(R.start(nonce: "8c41d07e2b9fa365", resume: nil, cached: 0) == .network)
        #expect(R.start(nonce: "8c41d07e2b9fa365", resume: nil, cached: 4096) == .cached(length: 4096))
        #expect(R.start(nonce: "8c41d07e2b9fa365", resume: 1 << 20, cached: 4096) == .cached(length: 4096))
        #expect(R.start(nonce: "8c41d07e2b9fa365", resume: 1 << 20, cached: 0) == .seekToStart)
        #expect(R.start(nonce: "8c41d07e2b9fa365", resume: 0, cached: 0) == .network)
        // A computer that names no streams cannot be asked to continue one elsewhere.
        #expect(R.start(nonce: nil, resume: nil, cached: 4096) == .network)
    }

    /// A kept replay continues only when the computer resumes the same stream at exactly the
    /// offset the replay accepted; otherwise the stream starts again from its first byte.
    @Test func aKeptReplayContinuesOnlyWhereItStands() {
        typealias R = GPUStreamResume
        let kept = R.Kept(id: 1, nonce: "8c41d07e2b9fa365", ended: false, resumable: 1 << 20, suspended: true)
        #expect(R.plan(id: 1, nonce: "8c41d07e2b9fa365", resume: 1 << 20, kept: kept) == .continueKept(offset: 1 << 20))
        // Not resumed: the computer replays the stream from its start.
        #expect(R.plan(id: 1, nonce: "8c41d07e2b9fa365", resume: nil, kept: kept) == .fresh)
        // Another stream under the same id, or another offset, cannot continue this replay.
        #expect(R.plan(id: 1, nonce: "0123456789abcdef", resume: 1 << 20, kept: kept) == .notKept)
        #expect(R.plan(id: 1, nonce: "8c41d07e2b9fa365", resume: 1, kept: kept) == .notKept)
        #expect(R.plan(id: 1, nonce: nil, resume: nil, kept: kept) == .fresh)
        // A replay still settling, or one that stopped, is not resumable.
        var settling = kept
        settling.resumable = nil
        #expect(R.plan(id: 1, nonce: "8c41d07e2b9fa365", resume: nil, kept: settling) == .fresh)
        #expect(R.plan(id: 1, nonce: "8c41d07e2b9fa365", resume: 1 << 20, kept: settling) == .notKept)
        // A stream already live on this connection, or ended here, stays as it is.
        let live = R.Kept(id: 1, nonce: "8c41d07e2b9fa365", ended: false, resumable: nil, suspended: false)
        #expect(R.plan(id: 1, nonce: "8c41d07e2b9fa365", resume: nil, kept: live) == .keep)
        var ended = kept
        ended.ended = true
        #expect(R.plan(id: 1, nonce: "8c41d07e2b9fa365", resume: 1 << 20, kept: ended) == .keep)
        // A window with another stream, or none, starts the new one.
        #expect(R.plan(id: 2, nonce: "0123456789abcdef", resume: nil, kept: kept) == .fresh)
        #expect(R.plan(id: 2, nonce: nil, resume: nil, kept: nil) == .fresh)
        #expect(R.plan(id: 2, nonce: nil, resume: 7, kept: nil) == .notKept)
    }

    /// Only settled, named replays are claimed, and only for the server epoch they came from.
    @Test func helloClaimsOnlyResumableReplays() {
        typealias R = GPUStreamResume
        let streams: [(id: Int, nonce: String?, offset: UInt64?)] = [
            (id: 9, nonce: "0123456789abcdef", offset: 0),
            (id: 1, nonce: "8c41d07e2b9fa365", offset: 1 << 20),
            (id: 2, nonce: nil, offset: 5),
            (id: 3, nonce: "fedcba9876543210", offset: nil),
        ]
        #expect(R.claims(epoch: "5f3a9c01d2e4b678", streams: streams) == GPUResume(epoch: "5f3a9c01d2e4b678", streams: [
            GPUResume.Stream(id: 1, nonce: "8c41d07e2b9fa365", offset: 1 << 20),
            GPUResume.Stream(id: 9, nonce: "0123456789abcdef", offset: 0),
        ]))
        #expect(R.claims(epoch: nil, streams: streams) == nil)
        #expect(R.claims(epoch: "5f3a9c01d2e4b678", streams: [(id: 2, nonce: nil, offset: 5)]) == nil)
    }

    @Test @MainActor func streamsPlayAndEndIndependently() {
        let first = RemoteGPUStream(id: 1, window: 7, feed: GPUStreamFeed()) { _ in }
        let second = RemoteGPUStream(id: 2, window: 9, feed: GPUStreamFeed()) { _ in }
        #expect(first.status == .playing)
        #expect(second.status == .playing)
        #expect(RemoteGPUStream.message(for: second.status) == nil)
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

    /// A replay that fails on its own ends visibly without affecting another stream; an
    /// event from an earlier replay of the stream changes nothing.
    @Test @MainActor func aFailedReplayDoesNotAffectAnotherStream() {
        let first = RemoteGPUStream(id: 1, window: 7, feed: GPUStreamFeed()) { _ in }
        let second = RemoteGPUStream(id: 2, window: 9, feed: GPUStreamFeed()) { _ in }
        first.replayEnded(playback: first.currentPlayback - 1, failure: "stale")
        #expect(first.status == .playing)
        first.replayEnded(playback: first.currentPlayback, failure: "VK_ERROR_DEVICE_LOST")
        #expect(first.status == .ended(reason: "replay: VK_ERROR_DEVICE_LOST"))
        #expect(RemoteGPUStream.message(for: first.status)?.contains("VK_ERROR_DEVICE_LOST") == true)
        #expect(second.status == .playing)
        second.end()
    }

    /// Releasing a stream has no scheduling effect on other windows.
    @Test @MainActor func releasingOneStreamLeavesAnotherPlaying() {
        var first: RemoteGPUStream? = RemoteGPUStream(id: 1, window: 7, feed: GPUStreamFeed()) { _ in }
        weak var released = first
        let second = RemoteGPUStream(id: 2, window: 9, feed: GPUStreamFeed()) { _ in }
        first = nil
        #expect(released == nil)
        #expect(second.status == .playing)
        second.end()
    }
}
