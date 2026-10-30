import Foundation

enum AudioRateStopCaller: String, Encodable {
    case unspecified, sessionStop, rendererFailure, interruptionBegan, interruptionEnded
}

/// Fixed-schema diagnostics only. No playback decision reads this state.
struct AudioRateProvenanceState {
    enum Reason: String, Encodable { case start, stop }
    struct Ticket: Equatable { let generation: UInt64; let sequence: UInt64 }
    struct Write: Encodable {
        var sequence: UInt64
        var reason: Reason
        var stopCaller: AudioRateStopCaller?
        var beginMonotonicSeconds: Double
        var beginWallUnixSeconds: Double
        var requestedRate: Double
        var beforeRate: Double
        var notificationsBefore: UInt64
        var endMonotonicSeconds: Double?
        var afterRate: Double?
        var notificationsAfter: UInt64?
    }
    struct Change: Encodable {
        var monotonicSeconds: Double
        var wallUnixSeconds: Double
        var observedRate: Double
        var openWriteSequence: UInt64?
        var latestWriteSequence: UInt64
    }
    struct Interruption: Encodable {
        var began: Bool
        var monotonicSeconds: Double
        var wallUnixSeconds: Double
    }
    struct Snapshot: Encodable {
        var generation: UInt64
        var writeCount: UInt64 = 0
        var rateChangeCount: UInt64 = 0
        var zeroRateChangeCount: UInt64 = 0
        var interruptionBeganCount: UInt64 = 0
        var interruptionEndedCount: UInt64 = 0
        var latestRateChange: Change?
        var latestZeroRateChange: Change?
        var latestInterruption: Interruption?
        var writes: [Write] = []
    }
    static let maximumWrites = 16
    private(set) var snapshot: Snapshot
    private var active = true
    private var inFlight: UInt64?

    init(generation: UInt64) { snapshot = Snapshot(generation: generation) }
    mutating func invalidate() { active = false; inFlight = nil }

    mutating func begin(reason: Reason, stopCaller: AudioRateStopCaller?, requested: Double,
                        before: Double, monotonic: Double, wall: Double) -> Ticket? {
        guard active, requested.isFinite, before.isFinite, monotonic.isFinite, wall.isFinite else { return nil }
        snapshot.writeCount &+= 1
        let sequence = snapshot.writeCount
        inFlight = sequence
        snapshot.writes.append(Write(sequence: sequence, reason: reason, stopCaller: stopCaller,
                                    beginMonotonicSeconds: monotonic, beginWallUnixSeconds: wall,
                                    requestedRate: requested, beforeRate: before,
                                    notificationsBefore: snapshot.rateChangeCount))
        if snapshot.writes.count > Self.maximumWrites { snapshot.writes.removeFirst(snapshot.writes.count - Self.maximumWrites) }
        return Ticket(generation: snapshot.generation, sequence: sequence)
    }

    mutating func end(_ ticket: Ticket, after: Double, monotonic: Double) {
        guard active, ticket.generation == snapshot.generation, inFlight == ticket.sequence,
              let index = snapshot.writes.firstIndex(where: { $0.sequence == ticket.sequence }) else { return }
        snapshot.writes[index].endMonotonicSeconds = monotonic.isFinite ? monotonic : nil
        snapshot.writes[index].afterRate = after.isFinite ? after : nil
        snapshot.writes[index].notificationsAfter = snapshot.rateChangeCount
        inFlight = nil
    }

    mutating func changed(generation: UInt64, rate: Double, monotonic: Double, wall: Double) {
        guard active, generation == snapshot.generation, rate.isFinite, monotonic.isFinite, wall.isFinite else { return }
        snapshot.rateChangeCount &+= 1
        if rate == 0 { snapshot.zeroRateChangeCount &+= 1 }
        snapshot.latestRateChange = Change(monotonicSeconds: monotonic, wallUnixSeconds: wall,
                                          observedRate: rate, openWriteSequence: inFlight,
                                          latestWriteSequence: snapshot.writeCount)
        if rate == 0 { snapshot.latestZeroRateChange = snapshot.latestRateChange }
    }

    mutating func interrupted(began: Bool, monotonic: Double, wall: Double) {
        guard active, monotonic.isFinite, wall.isFinite else { return }
        if began { snapshot.interruptionBeganCount &+= 1 } else { snapshot.interruptionEndedCount &+= 1 }
        snapshot.latestInterruption = Interruption(began: began, monotonicSeconds: monotonic, wallUnixSeconds: wall)
    }
}

/// Never hold this lock while calling AVFoundation, the recorder, or MediaClock.
final class AudioRateProvenance: @unchecked Sendable {
    private static let identityLock = NSLock()
    private static var nextIdentity: UInt64 = 0
    let generation: UInt64
    private let lock = NSLock()
    private var state: AudioRateProvenanceState

    init() {
        Self.identityLock.lock()
        Self.nextIdentity &+= 1
        generation = Self.nextIdentity
        Self.identityLock.unlock()
        state = AudioRateProvenanceState(generation: generation)
    }

    func update<T>(_ body: (inout AudioRateProvenanceState) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }
}
