import CoreGraphics

/// Distance-based dismissal: horizontal/downward starts belong to surrounding scrolling.
/// Velocity never turns a short swipe into a destructive action.
public struct UpwardDismissal: Sendable {
    public static let threshold: CGFloat = 64
    public private(set) var isActive = false

    public init() {}

    public static func isUpward(_ translation: CGPoint) -> Bool {
        translation.x.isFinite && translation.y.isFinite
            && -translation.y > abs(translation.x) * 1.5
    }

    public static func progress(_ translation: CGPoint) -> CGFloat {
        guard isUpward(translation) else { return 0 }
        return min(1, -translation.y / threshold)
    }

    public mutating func begin(_ translation: CGPoint) {
        isActive = Self.isUpward(translation)
    }

    /// Consumes the gesture, including unsuccessful releases, exactly once.
    public mutating func finish(_ translation: CGPoint) -> Bool {
        let dismiss = isActive && Self.progress(translation) == 1
        cancel()
        return dismiss
    }

    public mutating func cancel() { isActive = false }
}
