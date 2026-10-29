import Foundation

/// What a display connection measured, for the person to read. Every value comes from
/// something this client observed; a value it has no sample for is nil, never estimated.
public struct DisplayLinkHealth: Equatable, Sendable {
    /// Recent samples of one quantity, in milliseconds.
    public struct Samples: Equatable, Sendable {
        public var last: Double
        public var median: Double
        public var worst: Double
        public var count: Int
    }

    /// Ping to pong through the host's relay to the computer's display and back.
    public var roundTrip: Samples?
    /// Seconds since any byte arrived on this connection.
    public var sinceLastReceive: Double?
    /// Bits per second received over the last few seconds.
    public var receiveRate: Double?
    /// Window pictures applied per second over the last few seconds, all windows together.
    public var picturesPerSecond: Double?
    /// From a picture arriving on the socket to its decode starting: the client's own queue.
    public var decodeWait: Samples?
    /// Decoding one picture.
    public var decode: Samples?
    public var decodeFailures: Int
    /// What the socket has not finished sending. Nil where the transport does not report it.
    public var sendBacklog: SendBacklog?
    /// The median time from a key press to the next picture of the same window.
    public var typingEchoMs: Int?
    /// Seconds since a key press whose window has not drawn since.
    public var keyAwaitingPicture: Double?

    public static let empty = DisplayLinkHealth(decodeFailures: 0)
}

/// Messages handed to a socket that it has not finished sending.
public struct SendBacklog: Equatable, Sendable {
    public var count: Int
    /// How long the oldest has waited, in milliseconds; nil when nothing waits.
    public var oldestMs: Double?

    public init(count: Int, oldestMs: Double?) {
        self.count = count
        self.oldestMs = oldestMs
    }
}

/// Thread-safe counters fed from the socket queue, the decode queues and the main actor.
/// Times are seconds on `CACurrentMediaTime`'s clock (passed in, so tests choose them).
final class ConnectionMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var rtt = Ring(capacity: 20)
    private var wait = Ring(capacity: 60)
    private var decodeTime = Ring(capacity: 60)
    private var failures = 0
    private var lastReceive: Double?
    private var firstReceive: Double?
    private var received = Buckets()
    private var pictures = Buckets()
    private var firstPicture: Double?
    private var lastPicture: [Int: Double] = [:]

    /// Seconds over which rates are averaged.
    static let rateWindow: Double = 5

    func receive(bytes: Int, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        lastReceive = now
        if firstReceive == nil { firstReceive = now }
        received.add(Double(bytes), at: now)
    }

    var lastReceiveTime: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastReceive
    }

    func roundTrip(ms: Double) {
        lock.lock(); defer { lock.unlock() }
        rtt.add(ms)
    }

    /// One picture through a window's pipeline. `waited` and `took` in seconds.
    func picture(window: Int, waited: Double, took: Double, failed: Bool, at now: Double) {
        lock.lock(); defer { lock.unlock() }
        wait.add(waited * 1000)
        if failed {
            failures += 1
            return
        }
        decodeTime.add(took * 1000)
        lastPicture[window] = now
        if firstPicture == nil { firstPicture = now }
        pictures.add(1, at: now)
    }

    /// Seconds since the window's last applied picture, nil before its first on this connection.
    func pictureAge(window: Int, at now: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return lastPicture[window].map { max(0, now - $0) }
    }

    func snapshot(at now: Double) -> DisplayLinkHealth {
        lock.lock(); defer { lock.unlock() }
        var health = DisplayLinkHealth.empty
        health.roundTrip = rtt.samples
        health.decodeWait = wait.samples
        health.decode = decodeTime.samples
        health.decodeFailures = failures
        health.sinceLastReceive = lastReceive.map { max(0, now - $0) }
        health.receiveRate = Self.rate(received, since: firstReceive, at: now).map { $0 * 8 }
        health.picturesPerSecond = Self.rate(pictures, since: firstPicture, at: now)
        return health
    }

    /// Per second over the last `rateWindow` seconds, or since the first event when that is
    /// more recent; nil until a second has passed, which is too short to mean anything.
    private static func rate(_ buckets: Buckets, since first: Double?, at now: Double) -> Double? {
        guard let first else { return nil }
        let span = min(rateWindow, now - first)
        guard span >= 1 else { return nil }
        return buckets.sum(after: now - span, at: now) / span
    }

    /// The last `capacity` values.
    private struct Ring {
        let capacity: Int
        private var values: [Double] = []
        private var next = 0
        private var newest: Double?

        init(capacity: Int) { self.capacity = capacity }

        mutating func add(_ value: Double) {
            newest = value
            if values.count < capacity { values.append(value) } else { values[next] = value }
            next = (next + 1) % capacity
        }

        var samples: DisplayLinkHealth.Samples? {
            guard let newest, !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return .init(last: newest, median: sorted[sorted.count / 2], worst: sorted[sorted.count - 1], count: sorted.count)
        }
    }

    /// Amounts in tenth-of-a-second buckets, for the last `rateWindow` seconds and a little more.
    private struct Buckets {
        private var entries: [(slot: Int, amount: Double)] = []

        mutating func add(_ amount: Double, at now: Double) {
            let slot = Int((now * 10).rounded(.down))
            if let last = entries.last, last.slot == slot { entries[entries.count - 1].amount += amount }
            else { entries.append((slot, amount)) }
            let oldest = slot - Int(ConnectionMetrics.rateWindow * 10) - 10
            if let first = entries.first, first.slot < oldest { entries.removeAll { $0.slot < oldest } }
        }

        func sum(after start: Double, at now: Double) -> Double {
            let from = Int((start * 10).rounded(.down)), to = Int((now * 10).rounded(.down))
            return entries.reduce(0) { $1.slot >= from && $1.slot <= to ? $0 + $1.amount : $0 }
        }
    }
}
