import CoreGraphics
import Foundation

/// Pure phone-as-trackpad policy. One finger points or taps; tap-and-a-half drags.
/// Two fingers scroll, pinch to zoom, or tap to right-click. Three fingers drag;
/// four fingers swipe between workspaces or show/hide the window overview.
/// Finger-count changes rebase coordinates so staggered arrivals never move the cursor.
/// After a multi-finger lift, remaining fingers are ignored until all fingers lift.
public struct TrackpadGestures {
    public enum Direction: Equatable, Sendable { case left, right, up, down }

    public enum Action: Equatable, Sendable {
        case move(CGPoint)
        case scroll(CGPoint)
        case beginDrag
        case endDrag
        case click(button: Int)
        /// The second tap of a double-click.
        case doubleClick
        case workspace(Direction)
        /// Incremental natural-log scale: positive expands, negative contracts.
        /// Apply a scale factor of `exp(delta)`. The first event includes the change
        /// accumulated before recognition; subsequent events are relative to the last sample.
        case zoom(CGFloat)
    }

    public struct Tuning: Sendable {
        public var tapDuration: TimeInterval = 0.25
        public var twoFingerTapDuration: TimeInterval = 0.4
        public var tapSlop: CGFloat = 10
        public var twoFingerTapSlop: CGFloat = 28
        public var dragWindow: TimeInterval = 0.3
        public var dragSlop: CGFloat = 3
        /// Minimum centroid displacement before selecting scroll when spread is available.
        public var scrollSlop: CGFloat = 4
        /// A pinch must exceed both radial and logarithmic scale thresholds.
        public var pinchSlop: CGFloat = 4
        public var pinchLogSlop: CGFloat = 0.08
        /// Radial change must dominate translation for pinch; translation must dominate
        /// radial change for scroll. Once chosen, the mode lasts until a finger lifts.
        public var pinchDominance: CGFloat = 1.3
        public var workspaceSlop: CGFloat = 48
        public var workspaceDominance: CGFloat = 1.25
        public init() {}
    }

    public var tuning: Tuning
    private enum TwoFingerMode { case undecided, scroll, pinch }
    private var twoFingerMode: TwoFingerMode = .undecided
    private var start: TimeInterval = 0
    private var maxTouches = 0
    private var activeTouches = 0
    private var travel: CGFloat = 0
    private var phaseTravel: CGFloat = 0
    private var lastCentroid: CGPoint?
    private var phaseOrigin: CGPoint?
    private var initialSpread: CGFloat?
    private var lastSpread: CGFloat?
    private var lastTapEnded: TimeInterval = -.infinity
    private var dragArmed = false
    private var suppressed = false
    private var workspaceSent = false
    private var consumed = false
    public private(set) var dragging = false

    public init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// `touches` counts all fingers on the surface. Optional `spread` is their mean
    /// distance from the centroid, in points (for two fingers, half their separation).
    /// Omit spread to preserve immediate two-finger scrolling without pinch recognition.
    public mutating func began(touches: Int, centroid: CGPoint?, at time: TimeInterval,
                               spread: CGFloat? = nil) -> [Action] {
        guard touches > 0 else { return [] }
        if maxTouches == 0 {
            start = time
            travel = 0
            suppressed = false
            workspaceSent = false
            consumed = false
            dragArmed = touches == 1 && time - lastTapEnded < tuning.dragWindow
        }
        var actions: [Action] = []
        if dragging, touches != activeTouches {
            dragging = false
            actions.append(.endDrag)
        }
        maxTouches = max(maxTouches, touches)
        if touches >= 2 { dragArmed = false }
        activeTouches = touches
        lastCentroid = centroid
        phaseOrigin = centroid
        phaseTravel = 0
        initialSpread = valid(spread)
        lastSpread = initialSpread
        twoFingerMode = .undecided
        if touches > 4 { suppressed = true }
        return actions
    }

    public mutating func moved(touches: Int, centroid: CGPoint, at time: TimeInterval,
                               spread: CGFloat? = nil) -> [Action] {
        guard maxTouches > 0, !suppressed, touches == activeTouches,
              let last = lastCentroid else { return [] }
        let delta = CGPoint(x: centroid.x - last.x, y: centroid.y - last.y)
        lastCentroid = centroid
        let distance = hypot(delta.x, delta.y)
        travel += distance
        phaseTravel += distance
        let origin = phaseOrigin ?? centroid
        let displacement = CGPoint(x: centroid.x - origin.x, y: centroid.y - origin.y)

        if touches == 4 {
            guard !workspaceSent else { return [] }
            let x = abs(displacement.x), y = abs(displacement.y)
            let direction: Direction
            if x >= tuning.workspaceSlop, x >= y * tuning.workspaceDominance {
                direction = displacement.x < 0 ? .left : .right
            } else if y >= tuning.workspaceSlop, y >= x * tuning.workspaceDominance {
                direction = displacement.y < 0 ? .up : .down
            } else { return [] }
            workspaceSent = true
            return [.workspace(direction)]
        }
        if touches == 2 {
            return twoFingerMovement(delta: delta, displacement: displacement, spread: valid(spread))
        }
        var actions: [Action] = []
        if !dragging, (touches == 3 || dragArmed), phaseTravel >= tuning.dragSlop {
            dragArmed = false
            dragging = true
            consumed = true
            actions.append(.beginDrag)
        }
        // Three fingers do not point before their drag has been recognized.
        guard touches == 1 || dragging else { return [] }
        let gain = 1.4 + min(distance * 0.12, 2.6)
        actions.append(.move(CGPoint(x: delta.x * gain, y: delta.y * gain)))
        return actions
    }

    private mutating func twoFingerMovement(delta: CGPoint, displacement: CGPoint,
                                            spread: CGFloat?) -> [Action] {
        let translation = hypot(displacement.x, displacement.y)
        if translation >= tuning.scrollSlop { consumed = true }
        if twoFingerMode == .undecided {
            if let spread, let initialSpread {
                let radial = abs(spread - initialSpread)
                let logScale = log(spread / initialSpread)
                if radial >= tuning.pinchSlop, abs(logScale) >= tuning.pinchLogSlop,
                   radial >= translation * tuning.pinchDominance {
                    twoFingerMode = .pinch
                    consumed = true
                    lastSpread = spread
                    return [.zoom(logScale)]
                }
                if translation >= tuning.scrollSlop, translation >= radial * tuning.pinchDominance {
                    twoFingerMode = .scroll
                    return [.scroll(CGPoint(x: -displacement.x * 2, y: -displacement.y * 2))]
                }
                return []
            }
            twoFingerMode = .scroll
        }
        if twoFingerMode == .pinch {
            guard let spread, let previous = lastSpread else { return [] }
            lastSpread = spread
            let change = log(spread / previous)
            return change == 0 ? [] : [.zoom(change)]
        }
        return [.scroll(CGPoint(x: -delta.x * 2, y: -delta.y * 2))]
    }

    public mutating func ended(remaining: Int, centroid: CGPoint?, at time: TimeInterval,
                               spread: CGFloat? = nil) -> [Action] {
        guard maxTouches > 0 else { return [] }
        lastCentroid = centroid
        activeTouches = remaining
        if remaining > 0 {
            suppressed = true
            if dragging {
                dragging = false
                lastTapEnded = -.infinity
                return [.endDrag]
            }
            return []
        }
        defer { reset() }
        let duration = time - start
        let still = travel < tuning.tapSlop && duration < tuning.tapDuration
        if maxTouches >= 3 {
            lastTapEnded = -.infinity
            return dragging ? [.endDrag] : []
        }
        if dragging {
            lastTapEnded = -.infinity
            return still ? [.endDrag, .doubleClick] : [.endDrag]
        }
        if maxTouches == 2 {
            lastTapEnded = -.infinity
            let tapped = !consumed && twoFingerMode != .pinch && travel < tuning.twoFingerTapSlop
                && duration < tuning.twoFingerTapDuration
            return tapped ? [.click(button: 3)] : []
        }
        if dragArmed {
            lastTapEnded = -.infinity
            return still ? [.doubleClick] : []
        }
        guard still else { lastTapEnded = -.infinity; return [] }
        lastTapEnded = time
        return [.click(button: 1)]
    }

    /// System cancellation clears tap history and releases any held button exactly once.
    public mutating func cancelled() -> [Action] {
        let actions: [Action] = dragging ? [.endDrag] : []
        reset()
        lastTapEnded = -.infinity
        return actions
    }

    private mutating func reset() {
        maxTouches = 0
        activeTouches = 0
        dragArmed = false
        dragging = false
        lastCentroid = nil
        phaseOrigin = nil
        initialSpread = nil
        lastSpread = nil
        twoFingerMode = .undecided
        suppressed = false
        workspaceSent = false
    }

    private func valid(_ spread: CGFloat?) -> CGFloat? {
        guard let spread, spread.isFinite, spread > 0 else { return nil }
        return spread
    }
}

/// Converts continuous pinch changes into bounded common desktop zoom shortcuts.
public struct TrackpadZoom {
    private var remainder: CGFloat = 0
    public init() {}
    public mutating func reset() { remainder = 0 }
    public mutating func consume(_ delta: CGFloat) -> Int {
        guard delta.isFinite else { return 0 }
        let threshold: CGFloat = 0.12
        remainder += min(0.96, max(-0.96, delta))
        let steps = min(8, max(-8, Int(remainder / threshold)))
        remainder -= CGFloat(steps) * threshold
        return steps
    }
}
