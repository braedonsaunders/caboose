import CoreGraphics
import Foundation

/// Pure phone-as-trackpad policy. One finger points or taps; tap-and-a-half drags.
/// Two fingers scroll, pinch to zoom, or tap to right-click. Three fingers drag;
/// four fingers swipe between workspaces or show/hide the window overview.
/// Finger-count changes rebase coordinates so staggered arrivals never move the cursor.
/// After a multi-finger lift, remaining fingers are ignored until all fingers lift.
public struct TrackpadGestures {
    /// One sample of a pinch (docs/input.md, Gestures).
    public struct PinchEvent: Equatable, Sendable {
        public var phase: GesturePhase
        public var scale: CGFloat
        public var rotation: CGFloat
        public var fingers: Int
        public init(phase: GesturePhase, scale: CGFloat, rotation: CGFloat, fingers: Int) {
            self.phase = phase; self.scale = scale; self.rotation = rotation; self.fingers = fingers
        }
    }

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
        /// A real pinch: its phase, the scale since it began (1 at `begin`), the
        /// rotation in degrees clockwise since the previous sample, and its fingers.
        case pinch(PinchEvent)
    }

    /// What a trackpad's finger feels for an action (`TrackpadFeedback` plays it).
    public enum Feedback: Equatable, Sendable {
        /// A click or a double-click's second click: the keyboard's light press.
        case click
        /// A right-click: firmer, so it is told from a click.
        case secondaryClick
        case dragBegan, dragEnded
    }

    /// The feedback for an action, if it has one: pointing, scrolling, zooming and switching
    /// workspaces have none of their own.
    public static func feedback(for action: Action) -> Feedback? {
        switch action {
        case .click(let button): return button == 3 ? .secondaryClick : .click
        case .doubleClick: return .click
        case .beginDrag: return .dragBegan
        case .endDrag: return .dragEnded
        case .move, .scroll, .workspace, .pinch: return nil
        }
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
        /// When true, three-finger swipes emit `.workspace(Direction)` instead of starting a
        /// three-finger drag, so Laptop's lower panel can use 3- or 4-finger swipes interchangeably.
        public var threeFingerSwipe = false
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
    private var lastAngle: CGFloat?
    private var pinchScale: CGFloat = 1
    private var pinchActive = false
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
                               spread: CGFloat? = nil, angle: CGFloat? = nil) -> [Action] {
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
        lastAngle = angle
        pinchScale = 1
        twoFingerMode = .undecided
        if touches > 4 { suppressed = true }
        return actions
    }

    public mutating func moved(touches: Int, centroid: CGPoint, at time: TimeInterval,
                               spread: CGFloat? = nil, angle: CGFloat? = nil) -> [Action] {
        guard maxTouches > 0, !suppressed, touches == activeTouches,
              let last = lastCentroid else { return [] }
        let delta = CGPoint(x: centroid.x - last.x, y: centroid.y - last.y)
        lastCentroid = centroid
        let distance = hypot(delta.x, delta.y)
        travel += distance
        phaseTravel += distance
        let origin = phaseOrigin ?? centroid
        let displacement = CGPoint(x: centroid.x - origin.x, y: centroid.y - origin.y)

        if touches == 4 || (touches == 3 && tuning.threeFingerSwipe) {
            guard !workspaceSent else { return [] }
            let slop = touches == 3 ? min(tuning.workspaceSlop, 36) : tuning.workspaceSlop
            let x = abs(displacement.x), y = abs(displacement.y)
            let direction: Direction
            if x >= slop, x >= y * tuning.workspaceDominance {
                direction = displacement.x < 0 ? .left : .right
            } else if y >= slop, y >= x * tuning.workspaceDominance {
                direction = displacement.y < 0 ? .up : .down
            } else { return [] }
            workspaceSent = true
            return [.workspace(direction)]
        }
        if touches == 2 {
            return twoFingerMovement(delta: delta, displacement: displacement, spread: valid(spread), angle: angle, touches: touches)
        }
        var actions: [Action] = []
        if !dragging, ((touches == 3 && !tuning.threeFingerSwipe) || dragArmed), phaseTravel >= tuning.dragSlop {
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
                                            spread: CGFloat?, angle: CGFloat?, touches: Int) -> [Action] {
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
                    pinchActive = true
                    lastSpread = spread
                    pinchScale = spread / initialSpread
                    let rotation = rotationSince(angle)
                    return [
                        .pinch(PinchEvent(phase: .begin, scale: 1, rotation: 0, fingers: touches)),
                        .pinch(PinchEvent(phase: .update, scale: pinchScale, rotation: rotation, fingers: touches)),
                    ]
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
            guard let spread, let initialSpread else { return [] }
            lastSpread = spread
            pinchScale = spread / initialSpread
            return [.pinch(PinchEvent(phase: .update, scale: pinchScale, rotation: rotationSince(angle), fingers: touches))]
        }
        return [.scroll(CGPoint(x: -delta.x * 2, y: -delta.y * 2))]
    }

    /// Degrees clockwise since the previous sample, wrapped to ±180.
    private mutating func rotationSince(_ angle: CGFloat?) -> CGFloat {
        guard let angle else { return 0 }
        defer { lastAngle = angle }
        guard let lastAngle else { return 0 }
        var degrees = (angle - lastAngle) * 180 / .pi
        while degrees > 180 { degrees -= 360 }
        while degrees < -180 { degrees += 360 }
        return degrees
    }

    public mutating func ended(remaining: Int, centroid: CGPoint?, at time: TimeInterval,
                               spread: CGFloat? = nil) -> [Action] {
        guard maxTouches > 0 else { return [] }
        lastCentroid = centroid
        activeTouches = remaining
        if remaining > 0 {
            suppressed = true
            if pinchActive {
                pinchActive = false
                return [.pinch(PinchEvent(phase: .end, scale: pinchScale, rotation: 0, fingers: maxTouches))]
            }
            if dragging {
                dragging = false
                lastTapEnded = -.infinity
                return [.endDrag]
            }
            return []
        }
        let wasPinching = pinchActive
        let finalScale = pinchScale
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
            if wasPinching {
                return [.pinch(PinchEvent(phase: .end, scale: finalScale, rotation: 0, fingers: 2))]
            }
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
        var actions: [Action] = dragging ? [.endDrag] : []
        if pinchActive {
            actions.append(.pinch(PinchEvent(phase: .cancel, scale: pinchScale, rotation: 0, fingers: 2)))
        }
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
        lastAngle = nil
        pinchScale = 1
        pinchActive = false
        twoFingerMode = .undecided
        suppressed = false
        workspaceSent = false
    }

    private func valid(_ spread: CGFloat?) -> CGFloat? {
        guard let spread, spread.isFinite, spread > 0 else { return nil }
        return spread
    }
}

