import Foundation

/// Frame-independent scrolling in view points. Input samples are accumulated without
/// rounding; the consumer drains once per display frame. No remote geometry is retained.
public struct ScrollPhysics {
    public private(set) var velocity = CGPoint.zero
    public private(set) var isCoasting = false
    private var pending = CGPoint.zero
    private var lastSample: TimeInterval?
    private var tracking = false
    private let decay = -log(0.998) * 1000

    public init() {}
    public var needsFrame: Bool { pending != .zero || isCoasting }

    public mutating func begin(at time: TimeInterval) {
        cancel()
        guard time.isFinite else { return }
        tracking = true
        lastSample = time
    }

    public mutating func append(_ delta: CGPoint, at time: TimeInterval) {
        guard tracking, time.isFinite, delta.x.isFinite, delta.y.isFinite else { return }
        guard let previous = lastSample, time >= previous else { return }
        let dt = time - previous
        pending.x += delta.x
        pending.y += delta.y
        guard dt > 0 else { return }
        let sample = CGPoint(x: delta.x / dt, y: delta.y / dt)
        let weight = dt > 0.12 ? 1 : 1 - exp(-dt / 0.035)
        velocity.x += (sample.x - velocity.x) * weight
        velocity.y += (sample.y - velocity.y) * weight
        lastSample = time
    }

    /// A pause before lifting stops the fling. UIKit pans may supply their measured
    /// release velocity; raw touch surfaces use the filtered sample velocity.
    public mutating func end(at time: TimeInterval, velocity measured: CGPoint? = nil, coast: Bool = true, remainingContacts: Int = 0) {
        // A partial lift cancels the sequence, including movement awaiting a frame.
        guard remainingContacts == 0 else { cancel(); return }
        guard tracking else { return }
        tracking = false
        if let measured, measured.x.isFinite, measured.y.isFinite { velocity = measured }
        let fresh = lastSample.map { time >= $0 && time - $0 <= 0.12 } ?? false
        let speed = hypot(velocity.x, velocity.y)
        isCoasting = coast && fresh && speed >= 80
        if !isCoasting { velocity = .zero }
        else if speed > 8000 {
            velocity.x *= 8000 / speed
            velocity.y *= 8000 / speed
        }
    }

    public mutating func frame(elapsed: TimeInterval) -> CGPoint {
        guard elapsed.isFinite, elapsed >= 0 else { cancel(); return .zero }
        if elapsed > 0.1 {
            // Drop stale movement after a rendering stall, but keep accepting a
            // finger that is still down. Cancelling tracking here strands the
            // recognizer's remaining changed events until the user lifts.
            pending = .zero
            velocity = .zero
            isCoasting = false
            return .zero
        }
        var result = pending
        pending = .zero
        guard isCoasting else { return result }
        let speed = hypot(velocity.x, velocity.y)
        // Integrate exactly, including the final partial frame at the stop threshold.
        let dt = min(elapsed, max(0, log(speed / 20) / decay))
        let factor = exp(-decay * dt)
        result.x += velocity.x * (1 - factor) / decay
        result.y += velocity.y * (1 - factor) / decay
        velocity.x *= factor
        velocity.y *= factor
        if dt < elapsed || hypot(velocity.x, velocity.y) <= 20.000001 {
            isCoasting = false
            velocity = .zero
        }
        return result
    }

    /// The distance coasting still covers within `horizon` seconds, at the same exact
    /// decay and stop threshold as `frame(elapsed:)`; zero while not coasting.
    public func projectedDistance(over horizon: TimeInterval) -> CGPoint {
        guard isCoasting, horizon > 0, horizon.isFinite else { return .zero }
        let speed = hypot(velocity.x, velocity.y)
        guard speed > 20 else { return .zero }
        let dt = min(horizon, log(speed / 20) / decay)
        let travelled = (1 - exp(-decay * dt)) / decay
        return CGPoint(x: velocity.x * travelled, y: velocity.y * travelled)
    }

    public mutating func cancel() {
        velocity = .zero
        pending = .zero
        lastSample = nil
        tracking = false
        isCoasting = false
    }
}
