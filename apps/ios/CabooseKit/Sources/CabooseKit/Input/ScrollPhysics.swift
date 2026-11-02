import Foundation

/// A finger scroll in view points, sampled for the computer: movement is accumulated
/// without rounding and drained once per display frame, and the lift carries the
/// finger's velocity. The computer's input system scrolls on kinetically from that
/// velocity (docs/input.md, "Kinetic scrolling"); nothing coasts on the phone.
public struct ScrollPhysics {
    public private(set) var velocity = CGPoint.zero
    private var pending = CGPoint.zero
    /// The lift waiting for the next frame: the velocity to send with the last movement.
    private var lift: CGPoint?
    private var lastSample: TimeInterval?
    private var tracking = false

    /// One display frame's share of the scroll.
    public struct Step: Equatable {
        public var delta: CGPoint
        /// Present on the frame that ends the scroll: the finger's velocity as it lifted,
        /// zero when it lifted still.
        public var lift: CGPoint?
    }

    public init() {}
    public var needsFrame: Bool { pending != .zero || lift != nil }

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

    /// The finger lifted. A pause before lifting lifts it still. UIKit pans may supply
    /// their measured release velocity; raw touch surfaces use the filtered sample
    /// velocity. `coast: false` (hardware scrolling, which has the system's own momentum)
    /// lifts still.
    public mutating func end(at time: TimeInterval, velocity measured: CGPoint? = nil, coast: Bool = true, remainingContacts: Int = 0) {
        // A partial lift cancels the sequence, including movement awaiting a frame.
        guard remainingContacts == 0 else { cancel(); return }
        guard tracking else { return }
        tracking = false
        if let measured, measured.x.isFinite, measured.y.isFinite { velocity = measured }
        let fresh = lastSample.map { time >= $0 && time - $0 <= 0.12 } ?? false
        lift = coast && fresh ? KineticScroll.liftVelocity(velocity) : .zero
        velocity = .zero
    }

    public mutating func frame(elapsed: TimeInterval) -> Step {
        guard elapsed.isFinite, elapsed >= 0 else { cancel(); return Step(delta: .zero) }
        if elapsed > 0.1 {
            // Drop stale movement after a rendering stall, but keep accepting a
            // finger that is still down, and still end a lifted one.
            pending = .zero
            velocity = .zero
        }
        defer { pending = .zero; lift = nil }
        return Step(delta: pending, lift: lift)
    }

    public mutating func cancel() {
        velocity = .zero
        pending = .zero
        lift = nil
        lastSample = nil
        tracking = false
    }
}

/// The computer's kinetic scrolling, as far as the phone needs to know it
/// (guest/display `input/scroll.rs`): which lifts coast, and for how long at most.
public enum KineticScroll {
    /// A lift slower than this (points per second) is a lift at rest, as a UIScrollView
    /// does not coast from it either.
    static let minimumSpeed: CGFloat = 80
    /// The computer's coasting, in window pixels per second: it starts at most this fast,
    /// slows as a UIScrollView normally decelerates, and ends at the stop speed.
    static let maximumSpeed: CGFloat = 30000
    static let decay = -log(0.998) * 1000
    static let stopSpeed: CGFloat = 20

    /// The velocity a lift sends: zero when too slow to coast.
    static func liftVelocity(_ velocity: CGPoint) -> CGPoint {
        let speed = hypot(velocity.x, velocity.y)
        guard speed.isFinite, speed >= minimumSpeed else { return .zero }
        return velocity
    }

    /// How long the computer coasts after a lift at `velocity` (window pixels per second).
    public static func duration(lifting velocity: CGPoint) -> TimeInterval {
        let speed = min(hypot(velocity.x, velocity.y), maximumSpeed)
        guard speed.isFinite, speed > stopSpeed else { return 0 }
        return log(speed / stopSpeed) / decay
    }
}
