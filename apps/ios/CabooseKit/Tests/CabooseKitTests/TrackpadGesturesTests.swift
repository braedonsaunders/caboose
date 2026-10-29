import CoreGraphics
import Foundation
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

    @Test func threeFingerDragStartsOnceAndEndsAtFirstLift() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: here, at: 1)
        _ = gestures.began(touches: 2, centroid: CGPoint(x: 130, y: 200), at: 1.02)
        _ = gestures.began(touches: 3, centroid: CGPoint(x: 160, y: 200), at: 1.04)
        #expect(gestures.moved(touches: 3, centroid: CGPoint(x: 162, y: 200), at: 1.05) == [])
        let start = gestures.moved(touches: 3, centroid: CGPoint(x: 164, y: 200), at: 1.06)
        #expect(clicks(start) == [.beginDrag])
        #expect(start.count == 2)
        #expect(clicks(gestures.moved(touches: 3, centroid: CGPoint(x: 180, y: 200), at: 1.1)) == [])
        #expect(gestures.ended(remaining: 2, centroid: here, at: 1.12) == [.endDrag])
        #expect(gestures.moved(touches: 2, centroid: .zero, at: 1.13) == [])
        #expect(gestures.ended(remaining: 1, centroid: here, at: 1.14) == [])
        #expect(gestures.moved(touches: 1, centroid: .zero, at: 1.15) == [])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.16) == [])
        #expect(!gestures.dragging)
    }

    @Test func threeFingerTapNeverRightClicks() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 3, centroid: here, at: 1)
        _ = gestures.ended(remaining: 2, centroid: here, at: 1.05)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.1) == [])
    }

    @Test func cancelledThreeFingerDragReleasesExactlyOnce() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 3, centroid: here, at: 1)
        _ = gestures.moved(touches: 3, centroid: CGPoint(x: 110, y: 200), at: 1.1)
        #expect(gestures.cancelled() == [.endDrag])
        #expect(gestures.cancelled() == [])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.2) == [])
        _ = gestures.began(touches: 1, centroid: here, at: 1.3)
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.35) == [.click(button: 1)])
    }

    @Test func fourthFingerReleasesDragAndRebasesSwipe() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 3, centroid: here, at: 1)
        _ = gestures.moved(touches: 3, centroid: CGPoint(x: 110, y: 200), at: 1.1)
        #expect(gestures.began(touches: 4, centroid: CGPoint(x: 200, y: 200), at: 1.12) == [.endDrag])
        #expect(gestures.moved(touches: 4, centroid: CGPoint(x: 247, y: 200), at: 1.2) == [])
        #expect(gestures.moved(touches: 4, centroid: CGPoint(x: 248, y: 200), at: 1.21) == [.workspace(.right)])
        #expect(gestures.moved(touches: 4, centroid: .zero, at: 1.22) == [])
        #expect(gestures.ended(remaining: 3, centroid: here, at: 1.23) == [])
        #expect(gestures.moved(touches: 3, centroid: .zero, at: 1.24) == [])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.25) == [])
    }

    @Test func workspaceSwipeDirectionsAndAxisArbitration() {
        let examples: [(CGPoint, TrackpadGestures.Direction)] = [
            (CGPoint(x: -48, y: 0), .left), (CGPoint(x: 48, y: 0), .right),
            (CGPoint(x: 0, y: -48), .up), (CGPoint(x: 0, y: 48), .down)
        ]
        for (point, direction) in examples {
            var gestures = TrackpadGestures()
            _ = gestures.began(touches: 4, centroid: .zero, at: 1)
            #expect(gestures.moved(touches: 4, centroid: point, at: 1.1) == [.workspace(direction)])
            #expect(gestures.cancelled() == [])
        }
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 4, centroid: .zero, at: 1)
        #expect(gestures.moved(touches: 4, centroid: CGPoint(x: 50, y: 50), at: 1.1) == [])
        #expect(gestures.moved(touches: 4, centroid: CGPoint(x: 70, y: 50), at: 1.2) == [.workspace(.right)])
    }

    @Test func fifthFingerSuppressesGestureUntilAllLift() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 4, centroid: .zero, at: 1)
        _ = gestures.began(touches: 5, centroid: .zero, at: 1.1)
        #expect(gestures.moved(touches: 5, centroid: here, at: 1.2) == [])
        _ = gestures.ended(remaining: 4, centroid: .zero, at: 1.3)
        #expect(gestures.moved(touches: 4, centroid: here, at: 1.4) == [])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.5) == [])
    }

    @Test func pinchEmitsIncrementalLogScaleAndNeverScrollsOrClicks() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 1, centroid: .zero, at: 1)
        _ = gestures.began(touches: 2, centroid: here, at: 1.02, spread: 50)
        #expect(gestures.moved(touches: 2, centroid: here, at: 1.03, spread: 53) == [])
        #expect(gestures.moved(touches: 2, centroid: here, at: 1.04, spread: 60) == [.zoom(log(1.2))])
        #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 150, y: 200), at: 1.05, spread: 66) == [.zoom(log(1.1))])
        #expect(gestures.moved(touches: 2, centroid: here, at: 1.06, spread: 33) == [.zoom(log(0.5))])
        #expect(gestures.ended(remaining: 1, centroid: .zero, at: 1.07) == [])
        #expect(gestures.moved(touches: 1, centroid: here, at: 1.08) == [])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.09) == [])
    }

    @Test func normalScrollLatchesDespiteLaterSpreadChange() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 2, centroid: .zero, at: 1, spread: 50)
        #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 0, y: 3), at: 1.01, spread: 51) == [])
        #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 0, y: 5), at: 1.02, spread: 51) == [.scroll(CGPoint(x: 0, y: -10))])
        #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 0, y: 6), at: 1.03, spread: 80) == [.scroll(CGPoint(x: 0, y: -2))])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.1) == [])
    }

    @Test func ambiguousPinchAndScrollWaitForDominantMotion() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 2, centroid: .zero, at: 1, spread: 50)
        #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 5, y: 0), at: 1.1, spread: 55) == [])
        #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 5, y: 0), at: 1.2, spread: 60) == [.zoom(log(1.2))])
    }

    @Test func invalidOrMissingSpreadDoesNotProduceInvalidZoom() {
        let spreads: [CGFloat?] = [nil, 0, -1, .infinity, .nan]
        for spread in spreads {
            var gestures = TrackpadGestures()
            _ = gestures.began(touches: 2, centroid: .zero, at: 1, spread: spread)
            #expect(gestures.moved(touches: 2, centroid: CGPoint(x: 0, y: 10), at: 1.1, spread: spread) == [.scroll(CGPoint(x: 0, y: -20))])
        }
    }

    @Test func twoFingerLiftDoesNotTurnRemainingFingerIntoPointer() {
        var gestures = TrackpadGestures()
        _ = gestures.began(touches: 2, centroid: here, at: 1)
        _ = gestures.ended(remaining: 1, centroid: .zero, at: 1.1)
        #expect(gestures.moved(touches: 1, centroid: here, at: 1.15) == [])
        #expect(gestures.ended(remaining: 0, centroid: nil, at: 1.2) == [.click(button: 3)])
    }
}

struct TrackpadZoomTests {
    @Test func smallChangesAccumulateAndReverse() {
        var zoom = TrackpadZoom()
        #expect(zoom.consume(0.07) == 0)
        #expect(zoom.consume(0.07) == 1)
        #expect(zoom.consume(-0.15) == -1)
    }
    @Test func resetAndInvalidInputDoNotLeakIntoNextPinch() {
        var zoom = TrackpadZoom()
        #expect(zoom.consume(0.1) == 0)
        zoom.reset()
        #expect(zoom.consume(0.05) == 0)
        #expect(zoom.consume(.infinity) == 0)
        #expect(zoom.consume(.nan) == 0)
    }
    @Test func enormousJumpsAreBounded() {
        var zoom = TrackpadZoom()
        #expect(zoom.consume(1_000_000) == 8)
        #expect(zoom.consume(-1_000_000) == -8)
    }
}
