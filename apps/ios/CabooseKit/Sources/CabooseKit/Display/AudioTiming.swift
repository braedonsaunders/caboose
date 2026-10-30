import Foundation

/// Constant-space interval maxima. All timestamps use ProcessInfo.systemUptime;
/// tests supply timestamps directly. Receipt is the app's socket callback, not wire arrival.
struct AudioTimingInterval: Equatable, Encodable {
    var receipts = 0
    var packets = 0
    var receiptGap: TimeInterval = 0
    var incomingWait: TimeInterval = 0
    var incomingWork: TimeInterval = 0
    var audioReceiptGap: TimeInterval = 0
    var dispatchGap: TimeInterval = 0
    var queueEntryGap: TimeInterval = 0
    var decodeCompletionGap: TimeInterval = 0
    var enqueueCompletionGap: TimeInterval = 0
    var receiptToDispatch: TimeInterval = 0
    var queueWait: TimeInterval = 0
    var decode: TimeInterval = 0
    var prepare: TimeInterval = 0
    var enqueue: TimeInterval = 0
    var total: TimeInterval = 0

    /// Every duration/gap is the maximum for the report interval, in milliseconds.
    var logFields: String {
        let fields: [(String, TimeInterval)] = [
            ("rx_gap_ms", receiptGap), ("incoming_wait_ms", incomingWait), ("incoming_ms", incomingWork),
            ("audio_rx_gap_ms", audioReceiptGap), ("dispatch_gap_ms", dispatchGap),
            ("entry_gap_ms", queueEntryGap), ("decoded_gap_ms", decodeCompletionGap),
            ("enqueued_gap_ms", enqueueCompletionGap), ("rx_dispatch_ms", receiptToDispatch),
            ("queue_ms", queueWait), ("decode_ms", decode), ("prepare_ms", prepare),
            ("enqueue_ms", enqueue), ("total_ms", total)
        ]
        return "rx_n=\(receipts) timed_n=\(packets) " + fields.map { "\($0.0)=\(Int($0.1 * 1000))" }.joined(separator: " ")
    }
}

struct AudioTimingAccumulator {
    private var interval = AudioTimingInterval()
    private var receipt: TimeInterval?
    private var audioReceipt: TimeInterval?
    private var dispatched: TimeInterval?
    private var entered: TimeInterval?
    private var decoded: TimeInterval?
    private var enqueued: TimeInterval?

    static func elapsed(_ end: TimeInterval, since start: TimeInterval) -> TimeInterval {
        guard end.isFinite, start.isFinite else { return 0 }
        let duration = end - start
        return duration.isFinite ? max(0, duration) : 0
    }

    mutating func receive(at time: TimeInterval, incoming: TimeInterval) {
        interval.receipts += 1
        if let receipt { interval.receiptGap = max(interval.receiptGap, Self.elapsed(time, since: receipt)) }
        receipt = time
        interval.incomingWait = max(interval.incomingWait, Self.elapsed(incoming, since: time))
    }

    mutating func finishIncoming(start: TimeInterval, end: TimeInterval) {
        interval.incomingWork = max(interval.incomingWork, Self.elapsed(end, since: start))
    }

    mutating func packet(received: TimeInterval, dispatched: TimeInterval, entered: TimeInterval,
                         decoded: TimeInterval?, enqueueStarted: TimeInterval?, enqueued: TimeInterval?,
                         finished: TimeInterval) {
        interval.packets += 1
        if let previous = audioReceipt { interval.audioReceiptGap = max(interval.audioReceiptGap, Self.elapsed(received, since: previous)) }
        if let previous = self.dispatched { interval.dispatchGap = max(interval.dispatchGap, Self.elapsed(dispatched, since: previous)) }
        if let previous = self.entered { interval.queueEntryGap = max(interval.queueEntryGap, Self.elapsed(entered, since: previous)) }
        audioReceipt = received; self.dispatched = dispatched; self.entered = entered
        interval.receiptToDispatch = max(interval.receiptToDispatch, Self.elapsed(dispatched, since: received))
        interval.queueWait = max(interval.queueWait, Self.elapsed(entered, since: dispatched))
        interval.total = max(interval.total, Self.elapsed(finished, since: received))
        if let decoded {
            if let previous = self.decoded { interval.decodeCompletionGap = max(interval.decodeCompletionGap, Self.elapsed(decoded, since: previous)) }
            self.decoded = decoded
            interval.decode = max(interval.decode, Self.elapsed(decoded, since: entered))
            if let enqueueStarted { interval.prepare = max(interval.prepare, Self.elapsed(enqueueStarted, since: decoded)) }
        }
        if let enqueued, let enqueueStarted {
            if let previous = self.enqueued { interval.enqueueCompletionGap = max(interval.enqueueCompletionGap, Self.elapsed(enqueued, since: previous)) }
            self.enqueued = enqueued
            interval.enqueue = max(interval.enqueue, Self.elapsed(enqueued, since: enqueueStarted))
        }
    }

    /// Keep the preceding timestamps so gaps spanning reports remain visible.
    mutating func takeInterval() -> AudioTimingInterval {
        let result = interval
        interval = AudioTimingInterval()
        return result
    }

    /// A stopped/interrupted session must not count its idle time as a delivery stall.
    mutating func reset() { self = Self() }
}

/// Socket and audio queues contribute independently; no work or logging occurs under the lock.
final class AudioTimingMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = AudioTimingAccumulator()

    func update(_ body: (inout AudioTimingAccumulator) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&accumulator)
    }

    func takeInterval() -> AudioTimingInterval {
        lock.lock(); defer { lock.unlock() }
        return accumulator.takeInterval()
    }
}
