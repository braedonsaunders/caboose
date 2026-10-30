import Foundation

/// Numeric metadata only. No PCM, encoded packet, or external string enters this type.
struct AudioStartupRange: Encodable, Equatable {
    var minimum: Int64
    var maximum: Int64
    mutating func include(_ value: Int64) {
        minimum = min(minimum, value); maximum = max(maximum, value)
    }
    static func include(_ value: Int64?, in range: inout Self?) {
        guard let value else { return }
        if range == nil { range = Self(minimum: value, maximum: value) }
        else { range?.include(value) }
    }
}

struct AudioStartupBucket: Encodable {
    var generation: UInt64
    var index: Int
    var windowStartMonotonicSeconds: Double
    var firstReceiptMonotonicSeconds: Double
    var lastFinishedMonotonicSeconds: Double
    var firstReceiptWallUnixSeconds: Double
    var rawMinusPlacedMicros: AudioStartupRange?
    var rawStepMicros: AudioStartupRange?
    var placedStepMicros: AudioStartupRange?
    var decodedFrames: AudioStartupRange?
    var declaredBytes: AudioStartupRange?
    var copiedBytes: AudioStartupRange?
    var leadMicros: AudioStartupRange?
    var byteMismatchCount = 0
    var latePlacementCount = 0
    var timing = AudioTimingInterval()
}

/// One pending bucket, no timers/queues. Buckets close on the next packet or lifecycle
/// stop; empty buckets are omitted. Ingress time, not audio-queue execution time, defines
/// the window. A silence gap starts a fresh generation even after twelve seconds expired.
struct AudioStartupAccumulator {
    static let duration: Double = 12
    static let bucketDuration: Double = 0.25
    static let maximumBuckets = 48
    private(set) var generation: UInt64 = 0
    private var windowStart: Double?
    private var previousReceipt: Double?
    private var previousRaw: Int64?
    private var previousPlaced: Int64?
    private var pending: AudioStartupBucket?
    private var timing = AudioTimingAccumulator()

    struct Packet {
        var received: Double
        var dispatched: Double
        var entered: Double
        var decoded: Double?
        var enqueueStarted: Double?
        var enqueued: Double?
        var finished: Double
        var finishedWall: Double
        var rawPTS: Int64?
        var placedPTS: Int64?
        var frames: Int?
        var declaredBytes: Int?
        var copiedBytes: Int?
        var leadMicros: Int64?
    }

    mutating func observe(_ packet: Packet) -> AudioStartupBucket? {
        guard packet.received.isFinite, packet.finished.isFinite,
              packet.finishedWall.isFinite else { return nil }
        // Ignore stale receipt timestamps rather than making negative bucket indices.
        if let previousReceipt, packet.received < previousReceipt { return nil }
        let fresh = previousReceipt == nil || packet.received - previousReceipt! >= 1
        previousReceipt = packet.received
        var completed: AudioStartupBucket?
        if fresh {
            completed = finish()
            generation &+= 1
            windowStart = packet.received
            previousRaw = nil; previousPlaced = nil
            timing.reset()
        }
        guard let windowStart else { return completed }
        let elapsed = packet.received - windowStart
        guard elapsed < Self.duration else { return completed ?? finish() }
        let index = Int(elapsed / Self.bucketDuration)
        if pending?.index != index {
            completed = completed ?? finish()
            pending = AudioStartupBucket(generation: generation, index: index,
                windowStartMonotonicSeconds: windowStart, firstReceiptMonotonicSeconds: packet.received,
                lastFinishedMonotonicSeconds: packet.finished,
                firstReceiptWallUnixSeconds: packet.finishedWall - (packet.finished - packet.received))
        }
        timing.packet(received: packet.received, dispatched: packet.dispatched, entered: packet.entered,
                      decoded: packet.decoded, enqueueStarted: packet.enqueueStarted,
                      enqueued: packet.enqueued, finished: packet.finished)
        pending?.lastFinishedMonotonicSeconds = packet.finished
        if let raw = packet.rawPTS, let placed = packet.placedPTS {
            AudioStartupRange.include(raw - placed, in: &pending!.rawMinusPlacedMicros)
        }
        if let raw = packet.rawPTS {
            if let previousRaw { AudioStartupRange.include(raw - previousRaw, in: &pending!.rawStepMicros) }
            previousRaw = raw
        }
        if let placed = packet.placedPTS {
            if let previousPlaced { AudioStartupRange.include(placed - previousPlaced, in: &pending!.placedStepMicros) }
            previousPlaced = placed
        }
        AudioStartupRange.include(packet.frames.map(Int64.init), in: &pending!.decodedFrames)
        AudioStartupRange.include(packet.declaredBytes.map(Int64.init), in: &pending!.declaredBytes)
        AudioStartupRange.include(packet.copiedBytes.map(Int64.init), in: &pending!.copiedBytes)
        AudioStartupRange.include(packet.leadMicros, in: &pending!.leadMicros)
        if let lead = packet.leadMicros, lead < 0 { pending?.latePlacementCount += 1 }
        if let frames = packet.frames, let declared = packet.declaredBytes, let copied = packet.copiedBytes,
           frames > 0 && declared != copied { pending?.byteMismatchCount += 1 }
        return completed
    }

    mutating func finish() -> AudioStartupBucket? {
        guard var result = pending else { return nil }
        result.timing = timing.takeInterval()
        pending = nil
        return result
    }

    /// A new playback lifetime starts a fresh window; generation remains monotonic.
    mutating func reset() -> AudioStartupBucket? {
        let result = finish()
        previousReceipt = nil; windowStart = nil; previousRaw = nil; previousPlaced = nil
        timing.reset()
        return result
    }
}
