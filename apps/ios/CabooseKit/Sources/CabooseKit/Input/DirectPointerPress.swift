import Foundation

/// A stationary direct touch opens context at its original point, once. Movement,
/// additional fingers and cancellation permanently disarm that press.
public struct DirectPointerPress {
    private var origin: CGPoint?
    private var started: TimeInterval = 0
    public init() {}
    public mutating func begin(at point: CGPoint, time: TimeInterval) {
        origin = point
        started = time
    }
    public mutating func move(to point: CGPoint) {
        if let origin, hypot(point.x - origin.x, point.y - origin.y) > 8 { cancel() }
    }
    public mutating func cancel() { origin = nil }
    public mutating func context(at time: TimeInterval) -> CGPoint? {
        guard let point = origin, time - started >= 0.5 else { return nil }
        origin = nil
        return point
    }
}
