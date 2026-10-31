import Foundation

/// A critically damped spring toward zero, integrated exactly, for the bounce back from
/// past the end of content and for easing the phone's position onto the app's.
public struct ScrollSpring: Equatable, Sendable {
    public private(set) var offset: Double
    public private(set) var velocity: Double
    public let stiffness: Double

    /// - Parameter stiffness: natural angular frequency, rad/s; 10 settles in about half a second.
    public init(offset: Double, velocity: Double, stiffness: Double = 10) {
        self.offset = offset; self.velocity = velocity; self.stiffness = stiffness
    }

    public var isSettled: Bool { abs(offset) < 0.5 && abs(velocity) < 6 }

    public mutating func advance(_ elapsed: TimeInterval) {
        guard elapsed > 0, elapsed.isFinite else { return }
        let w = stiffness, x0 = offset, v0 = velocity
        let decay = exp(-w * elapsed), b = v0 + w * x0
        offset = (x0 + b * elapsed) * decay
        velocity = (v0 - w * elapsed * b) * decay
        if isSettled { offset = 0; velocity = 0 }
    }

    /// UIScrollView's resistance past the end of content: finger travel `distance` beyond
    /// the edge shows as this much, approaching but never reaching `dimension`.
    public static func rubberBand(_ distance: Double, dimension: Double) -> Double {
        guard dimension > 0 else { return 0 }
        let magnitude = (1 - 1 / (abs(distance) * 0.55 / dimension + 1)) * dimension
        return distance < 0 ? -magnitude : magnitude
    }
}
