import Foundation

/// Whether a window's GPU is keeping up, for the notice over it: lost once a present reports
/// its device lost (for the rest of the window's surface), stalled while a present has gone
/// `stalledAfter` seconds without the GPU releasing its source, running otherwise. Not
/// synchronized: its owner (the window's layer lease) guards it.
struct LiveGPUWindowHealth: Equatable {
    enum State: Equatable { case running, stalled, lost }
    static let stalledAfter: TimeInterval = 2
    /// Presents waited on, by serial, with when each was submitted. A window keeps at most a
    /// handful in flight; the oldest beyond 64 are forgotten.
    private(set) var pending: [UInt64: TimeInterval] = [:]
    private(set) var lost = false

    mutating func presented(_ serial: UInt64, at now: TimeInterval) {
        pending[serial] = now
        if pending.count > 64, let oldest = pending.min(by: { $0.value < $1.value }) { pending[oldest.key] = nil }
    }
    mutating func released(_ serial: UInt64) { pending[serial] = nil }
    mutating func deviceLost() { lost = true; pending.removeAll() }

    func state(at now: TimeInterval) -> State {
        if lost { return .lost }
        guard let oldest = pending.values.min() else { return .running }
        return now - oldest >= Self.stalledAfter ? .stalled : .running
    }
}
