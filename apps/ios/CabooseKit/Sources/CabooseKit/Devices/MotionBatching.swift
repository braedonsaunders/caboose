import Foundation

/// Core Motion's readings in the computer's units and conventions (docs/devices.md).
public enum MotionUnits {
    /// Standard gravity, m/s².
    public static let gravity = 9.80665
    /// The fastest rate the phone samples at.
    public static let maxRateHz = 100.0
    /// The rate used when the computer asks for none.
    public static let defaultRateHz = 100.0

    /// Core Motion's acceleration, in g with a phone face up reading `z = −1`, as Linux reads
    /// it: m/s² with face up reading `z = +9.81`.
    public static func linuxAcceleration(g: (x: Double, y: Double, z: Double)) -> [Double] {
        [g.x, g.y, g.z].map { value in
            let converted = -value * gravity
            return converted == 0 ? 0 : converted
        }
    }

    /// The rate to sample at for a `device.open` asking for `rateHz`.
    public static func rate(for rateHz: Double?) -> Double {
        guard let rateHz, rateHz.isFinite, rateHz > 0 else { return defaultRateHz }
        return min(maxRateHz, max(1, rateHz))
    }
}

/// Gathers motion samples into `device.motion` batches: one every 20 ms, or sooner once 64
/// are waiting. A barometer reading, which arrives about once a second, rides on the next
/// sample.
public struct MotionBatcher: Sendable {
    public static let interval: UInt64 = 20_000
    public static let maxSamples = 64

    private var samples: [MotionSample] = []
    private var pendingPressure: Double?

    public init() {}

    /// A new barometer reading in kPa, sent with the next sample.
    public mutating func pressure(_ kilopascals: Double) {
        pendingPressure = kilopascals
    }

    /// Adds `sample`; returns a batch when one is due.
    public mutating func add(_ sample: MotionSample) -> [MotionSample]? {
        var sample = sample
        if let pressure = pendingPressure {
            sample.pressure = pressure
            pendingPressure = nil
        }
        samples.append(sample)
        guard let first = samples.first else { return nil }
        if samples.count >= Self.maxSamples || sample.micros >= first.micros + Self.interval {
            defer { samples.removeAll(keepingCapacity: true) }
            return samples
        }
        return nil
    }

    /// Whatever is waiting, and starts afresh.
    public mutating func flush() -> [MotionSample] {
        defer { samples.removeAll() }
        return samples
    }

    public mutating func reset() {
        samples.removeAll()
        pendingPressure = nil
    }
}
