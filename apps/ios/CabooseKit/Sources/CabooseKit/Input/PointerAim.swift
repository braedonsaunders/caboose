import Foundation

/// Aiming a finger held on a mouse-only window: the hold that turns a finger into a precise
/// pointer, as the text loupe does on iOS.
///
/// Holding still starts aiming: the pointer hovers where the finger is and then moves at
/// half the finger's speed, so a control a few pixels wide can be reached by eye in the
/// loupe; lifting clicks there. Holding still again while aiming presses the button, and
/// the finger then drags from that exact point until it lifts.
public struct PointerAim: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, aiming, dragging }

    /// How much of the finger's travel the pointer follows while aiming.
    public static let gain: CGFloat = 0.5
    /// How long the finger stays still, while aiming, before the button goes down.
    public static let dragHold: TimeInterval = 0.5
    /// Travel, in points, that counts as moving rather than holding still.
    public static let stillSlop: CGFloat = 4

    public private(set) var phase = Phase.idle
    /// Where the pointer is, in the view's points.
    public private(set) var point = CGPoint.zero
    private var finger = CGPoint.zero
    /// Where the finger has stayed within `stillSlop` of since `stillSince`.
    private var anchor = CGPoint.zero
    private var stillSince: TimeInterval = 0

    public init() {}

    public mutating func begin(at finger: CGPoint, time: TimeInterval) {
        phase = .aiming
        point = finger
        self.finger = finger
        anchor = finger
        stillSince = time
    }

    /// The finger moved: the pointer follows at `gain` while aiming, and exactly while
    /// dragging (the drag is the finger's).
    public mutating func move(to finger: CGPoint, time: TimeInterval) {
        guard phase != .idle else { return }
        let scale = phase == .aiming ? Self.gain : 1
        point.x += (finger.x - self.finger.x) * scale
        point.y += (finger.y - self.finger.y) * scale
        self.finger = finger
        if hypot(finger.x - anchor.x, finger.y - anchor.y) > Self.stillSlop {
            anchor = finger
            stillSince = time
        }
    }

    /// Whether the finger has held still long enough, while aiming, to press the button.
    public func dragDue(at time: TimeInterval) -> Bool {
        phase == .aiming && time - stillSince >= Self.dragHold
    }

    /// The time at which the button goes down if the finger stays still.
    public var dragTime: TimeInterval { stillSince + Self.dragHold }

    public mutating func startDrag() {
        guard phase == .aiming else { return }
        phase = .dragging
    }

    /// The finger lifted or was taken away; what it was doing.
    @discardableResult
    public mutating func end() -> Phase {
        defer { phase = .idle }
        return phase
    }
}
