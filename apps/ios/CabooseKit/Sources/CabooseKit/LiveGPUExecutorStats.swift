import Foundation

/// The executor's always-on counters (docs/gpu-live.md, "Executor stats"), as EXECUTOR_STATS
/// carries them: caboose_gpu_executor_stats, twelve little-endian u64, the first its size.
/// Counters only; never handles, payloads or identities.
struct LiveGPUExecutorStats: Equatable, Sendable {
    static let size = 96
    var commands: UInt64 = 0, decodeMicroseconds: UInt64 = 0
    var readBytes: UInt64 = 0, readWaitMicroseconds: UInt64 = 0, flushMicroseconds: UInt64 = 0
    var submitted: UInt64 = 0, completed: UInt64 = 0, completionMicroseconds: UInt64 = 0
    var gpuBusyMicroseconds: UInt64 = 0, outstanding: UInt64 = 0, outstandingMax: UInt64 = 0

    var payload: Data {
        var data = Data(capacity: Self.size)
        for value in [UInt64(Self.size), commands, decodeMicroseconds, readBytes, readWaitMicroseconds,
                      flushMicroseconds, submitted, completed, completionMicroseconds, gpuBusyMicroseconds,
                      outstanding, outstandingMax] {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// The interval STATS_REQUEST asks for, in milliseconds (100 to 60 000), or nil.
    static func requestedInterval(_ payload: Data) -> UInt32? {
        guard payload.count == 8 else { return nil }
        let interval = payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        return (100...60_000).contains(interval) ? interval : nil
    }
}
