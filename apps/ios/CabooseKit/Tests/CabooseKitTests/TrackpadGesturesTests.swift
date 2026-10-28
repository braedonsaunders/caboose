import CoreGraphics
import Testing
@testable import CabooseKit

/// Real fingers land and lift a few milliseconds apart; every case here is staggered on purpose.
struct TrackpadGesturesTests {
    private let here = CGPoint(x: 100, y: 200)

    private func clicks(_ actions: [TrackpadGestures.Action]) -> [TrackpadGestures.Action] {
        actions.filter { if case .move = $0 { false } else if case .scroll = $0 { false } else { true } }
    }

    @Test func oneFingerTapClicks() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1.00)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.08) == [.click(button: 1)])
    }

    @Test func staggeredTwoFingerTapRightClicks() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1.00)
        // The second finger lands 40 ms later; the centroid jumps halfway to it.
        _ = gestures.began(touches: 2, centroid: CGPoint(x: 130, y: 200), at: 1.04)
        _ = gestures.moved(touches: 2, centroid: CGPoint(x: 131, y: 201), at: 1.08)
        // They lift one at a time; the centroid jumps back to the remaining finger.
        #expect(gestures.ended(remaining: 1, centroid: CGPoint(x: 160, y: 200), at: 1.15) == [])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.20) == [.click(button: 3)])
    }

    @Test func twoFingerTapRightAfterATapIsStillARightClick() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1.00)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.08) == [.click(button: 1)])
        // The first finger of the two lands inside the tap-and-a-half window, alone.
        _ = gestures.began(touches: 1, centroid: here, at: 1.20)
        _ = gestures.began(touches: 2, centroid: CGPoint(x: 120, y: 200), at: 1.23)
        _ = gestures.ended(remaining: 1, centroid: here, at: 1.30)
        let actions = gestures.ended(remaining: 0, centroid: nil, at: 1.33)
        #expect(actions == [.click(button: 3)], "not a drag or a double-click")
        #expect(!gestures.dragging)
    }

    @Test func twoFingersMovingScrollAndDoNotClick() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 2, centroid: here, at: 1.00)
        #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 100, y: 180), at: 1.05) == [.scroll(CGPoint(x: 0, y: 40))])
        _ = gestures.moved(touches: 2, centroid: CGPoint(x: 100, y: 150), at: 1.10)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.15) == [])
    }

    @Test func aSlowTwoFingerRestIsNotARightClick() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 2, centroid: here, at: 1.00)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.80) == [])
    }

    @Test func tapThenTapDoubleClicks() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1.00)
        _ = gestures.ended(remaining: 0, centroid: nil, at: 1.06)
        _ = gestures.began(touches: 1, centroid: here, at: 1.18)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.24) == [.doubleClick])
        // A third tap starts fresh rather than chaining into another double-click.
        _ = gestures.began(touches: 1, centroid: here, at: 1.36)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.42) == [.click(button: 1)])
    }

    @Test func tapAndAHalfDrags() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1.00)
        _ = gestures.ended(remaining: 0, centroid: nil, at: 1.06)
        _ = gestures.began(touches: 1, centroid: here, at: 1.20)
        // The drag starts with the first real movement, not when the finger lands.
        let first = gestures.moved(touches: 1, centroid: CGPoint(x: 101, y: 200), at: 1.22)
        #expect(clicks(first) == [])
        let second = gestures.moved(touches: 1, centroid: CGPoint(x: 140, y: 200), at: 1.30)
        #expect(clicks(second) == [.beginDrag])
        #expect(gestures.dragging)
        _ = gestures.moved(touches: 1, centroid: CGPoint(x: 200, y: 260), at: 1.60)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.90) == [.endDrag])
    }

    @Test func movingOneFingerOnlyMovesTheCursor() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1.00)
        let actions = gestures.moved(touches: 1, centroid: CGPoint(x: 110, y: 200), at: 1.05)
        guard case .move(let delta) = actions.first else { Issue.record("expected a move"); return }
        #expect(delta.x > 10, "accelerated")
        #expect(delta.y == 0)
        _ = gestures.moved(touches: 1, centroid: CGPoint(x: 160, y: 200), at: 1.10)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.15) == [])
    }

    @Test func cancellingReleasesAHeldDrag() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1.00)
        _ = gestures.ended(remaining: 0, centroid: nil, at: 1.06)
        _ = gestures.began(touches: 1, centroid: here, at: 1.20)
        _ = gestures.moved(touches: 1, centroid: CGPoint(x: 150, y: 200), at: 1.30)
        #expect(gestures.cancelled() == [.endDrag])
        #expect(gestures.cancelled() == [])
    }
}
