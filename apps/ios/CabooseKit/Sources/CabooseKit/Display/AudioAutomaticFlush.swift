import Foundation

/// Pure state for notifications delivered on arbitrary threads. A generation belongs
/// to one observer registration for one renderer playback lifetime, not a setRate call.
struct AudioAutomaticFlushState {
    struct Summary: Encodable {
        enum Reason: String, Encodable { case rendererNotification }
        var notifications: UInt64 = 0
        var recoveries: UInt64 = 0
        var reason: Reason = .rendererNotification
        var lastEventGeneration: UInt64?
        var lastMonotonicSeconds: Double?
        var lastWallUnixSeconds: Double?
        var lastFlushMicros: Int64?
    }
    private(set) var generation: UInt64 = 0
    private(set) var active = false
    private(set) var pending = false
    private(set) var scheduled = false
    private(set) var summary = Summary()

    mutating func begin() -> UInt64 {
        generation &+= 1
        active = true
        pending = false
        scheduled = false
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        active = false
        pending = false
        scheduled = false
    }

    /// True schedules one drain; a slow playback queue cannot accumulate notification jobs.
    mutating func notify(generation eventGeneration: UInt64, monotonic: Double, wall: Double, flushMicros: Int64?) -> Bool {
        guard active, eventGeneration == generation else { return false }
        summary.notifications &+= 1
        summary.lastEventGeneration = eventGeneration
        summary.lastMonotonicSeconds = monotonic.isFinite ? monotonic : nil
        summary.lastWallUnixSeconds = wall.isFinite ? wall : nil
        summary.lastFlushMicros = flushMicros
        pending = true
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    /// Called on the playback queue before enqueue or by the scheduled drain. The
    /// caller flushes the renderer after releasing the latch lock, on that same queue.
    mutating func take(generation eventGeneration: UInt64) -> Bool {
        guard active, eventGeneration == generation, pending else { return false }
        pending = false
        summary.recoveries &+= 1
        return true
    }

    /// Only a drain calls finish. A notification arriving during flush keeps one
    /// successor drain scheduled. A stale drain cannot clear a new generation's work.
    mutating func finish(generation eventGeneration: UInt64) -> Bool {
        guard active, eventGeneration == generation else { return false }
        if pending { return true }
        scheduled = false
        return false
    }
}

final class AudioAutomaticFlushLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var state = AudioAutomaticFlushState()
    func update<T>(_ body: (inout AudioAutomaticFlushState) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }
}
