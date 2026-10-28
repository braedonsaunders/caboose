import CoreGraphics
import Foundation

/// The phone-as-trackpad gesture rules, kept apart from UIKit so they can be tested.
///
/// One finger moves the cursor with acceleration and a tap clicks. Two fingers scroll,
/// and a two-finger tap right-clicks. Tap-and-a-half (tap, then touch down again and
/// move) drags, and two quick taps double-click.
///
/// Fingers rarely land or lift together. A second finger that arrives just after the
/// first is still a two-finger gesture, even when the first finger landed right after
/// a tap. A drag is armed by that second touch but only starts once the finger moves,
/// so a late second finger can still turn it into a right-click.
public struct TrackpadGestures {
    public enum Action: Equatable, Sendable {
        case move(CGPoint)
        case scroll(CGPoint)
        case beginDrag
        case endDrag
        case click(button: Int)
        /// The second tap of a double-click: press and release where the cursor is, then the double-click itself.
        case doubleClick
    }

    public struct Tuning: Sendable {
        /// The longest touch that still counts as a one-finger tap.
        public var tapDuration: TimeInterval = 0.25
        /// Two fingers land and lift less together, so their tap may last longer.
        public var twoFingerTapDuration: TimeInterval = 0.4
        /// How far a one-finger tap may wander, in points.
        public var tapSlop: CGFloat = 10
        /// How far the centroid of a two-finger tap may wander. It jumps as each finger lands and lifts.
        public var twoFingerTapSlop: CGFloat = 28
        /// A touch this soon after a tap arms tap-and-a-half.
        public var dragWindow: TimeInterval = 0.3
        /// Movement that turns an armed touch into a drag.
        public var dragSlop: CGFloat = 3
        public init() {}
    }

    public var tuning: Tuning

    private var start: TimeInterval = 0
    private var maxTouches = 0
    private var travel: CGFloat = 0
    private var lastCentroid: CGPoint?
    private var lastTapEnded: TimeInterval = -.infinity
    private var dragArmed = false
    public private(set) var dragging = false

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// Fingers touched down. `touches` counts every finger now on the surface.
    public mutating func began(touches: Int, centroid: CGPoint?, at time: TimeInterval) -> [Action] {
        if maxTouches == 0 {
            start = time
            travel = 0
            dragArmed = touches == 1 && time - lastTapEnded < tuning.dragWindow
        }
        maxTouches = max(maxTouches, touches)
        // A second finger before the drag moved makes this a two-finger gesture, not a drag.
        if touches >= 2, !dragging { dragArmed = false }
        lastCentroid = centroid
        return []
    }

    /// Fingers moved; `centroid` is the middle of every finger still down.
    public mutating func moved(touches: Int, centroid: CGPoint, at time: TimeInterval) -> [Action] {
        guard let last = lastCentroid else {
            lastCentroid = centroid
            return []
        }
        let delta = CGPoint(x: centroid.x - last.x, y: centroid.y - last.y)
        lastCentroid = centroid
        let distance = hypot(delta.x, delta.y)
        travel += distance
        if touches >= 2, !dragging {
            return [.scroll(CGPoint(x: -delta.x * 2, y: -delta.y * 2))]
        }
        var actions: [Action] = []
        if dragArmed, !dragging, travel >= tuning.dragSlop {
            dragArmed = false
            dragging = true
            actions.append(.beginDrag)
        }
        // Acceleration: slow moves are precise, fast flicks cross the screen.
        let gain = 1.4 + min(distance * 0.12, 2.6)
        actions.append(.move(CGPoint(x: delta.x * gain, y: delta.y * gain)))
        return actions
    }

    /// Fingers lifted. `remaining` counts fingers still down; the gesture ends when none are.
    public mutating func ended(remaining: Int, centroid: CGPoint?, at time: TimeInterval) -> [Action] {
        lastCentroid = centroid
        guard remaining == 0 else { return [] }
        defer {
            maxTouches = 0
            dragArmed = false
            dragging = false
        }
        let duration = time - start
        let still = travel < tuning.tapSlop && duration < tuning.tapDuration
        if dragging {
            lastTapEnded = -.infinity
            // A second tap that barely moved was a double-click, not a drag.
            return still ? [.endDrag, .doubleClick] : [.endDrag]
        }
        if maxTouches >= 2 {
            lastTapEnded = -.infinity
            let tapped = travel < tuning.twoFingerTapSlop && duration < tuning.twoFingerTapDuration
            return tapped ? [.click(button: 3)] : []
        }
        if dragArmed {
            lastTapEnded = -.infinity
            return still ? [.doubleClick] : []
        }
        guard still else { return [] }
        lastTapEnded = time
        return [.click(button: 1)]
    }

    /// The system took the touches (a call, a gesture); never leave a button held.
    public mutating func cancelled() -> [Action] {
        let actions: [Action] = dragging ? [.endDrag] : []
        maxTouches = 0
        dragArmed = false
        dragging = false
        lastCentroid = nil
        return actions
    }
}
