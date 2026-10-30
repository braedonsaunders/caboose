import Foundation

/// Bounds compressed packets retained by the playback queue, including its running job.
/// Scheduling under this lock orders lifecycle barriers with packet admission. The
/// scheduled work never runs inline and never holds this lock while decoding/enqueuing.
final class AudioIngress: @unchecked Sendable {
    struct Ticket: Sendable {
        let generation: UInt64
        let sequence: UInt64
        let bytes: Int
    }
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var packets = 0
    private var bytes = 0
    private var rejections: UInt64 = 0
    static let packetLimit = 16
    static let byteLimit = 64 * 1024

    func submit(bytes size: Int, schedule: (Ticket) -> Void) {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        guard size > 0, size <= Self.byteLimit,
              packets < Self.packetLimit, size <= Self.byteLimit - bytes else {
            rejections &+= 1
            return
        }
        packets += 1; bytes += size
        schedule(Ticket(generation: generation, sequence: sequence, bytes: size))
    }

    func invalidate(schedule: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        // Old jobs still own their permits until they exit; clearing counts here would
        // allow repeated stop/start to exceed the memory bound.
        schedule()
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket.generation == generation
    }

    func finish(_ ticket: Ticket) {
        lock.lock(); defer { lock.unlock() }
        packets -= 1; bytes -= ticket.bytes
    }

    var rejected: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return rejections
    }
}

/// Admission gaps must not be joined away by the ordinary timestamp-jitter tolerance.
struct AudioIngressContinuity {
    private var previous: UInt64?
    mutating func discontinuity(at sequence: UInt64) -> Bool {
        defer { previous = sequence }
        guard let previous else { return false }
        return sequence != previous &+ 1
    }
}
