import Foundation
import Testing
@testable import CabooseKit

@Suite struct PointerAimTests {
    @Test func aimingFollowsTheFingerAtHalfSpeedAndClicksOnLift() {
        var aim = PointerAim()
        aim.begin(at: CGPoint(x: 100, y: 100), time: 0)
        #expect(aim.phase == .aiming && aim.point == CGPoint(x: 100, y: 100))
        aim.move(to: CGPoint(x: 120, y: 90), time: 0.1)
        #expect(aim.point == CGPoint(x: 110, y: 95))
        #expect(aim.end() == .aiming && aim.phase == .idle)
    }

    @Test func holdingStillWhileAimingPressesAndThenDragsExactly() {
        var aim = PointerAim()
        aim.begin(at: CGPoint(x: 100, y: 100), time: 0)
        aim.move(to: CGPoint(x: 120, y: 100), time: 0.2) // moving resets the hold
        #expect(!aim.dragDue(at: 0.6))
        aim.move(to: CGPoint(x: 122, y: 101), time: 0.4) // within the slop: still holding
        #expect(abs(aim.dragTime - 0.7) < 1e-9 && aim.dragDue(at: 0.71))
        aim.startDrag()
        #expect(aim.phase == .dragging)
        let pressed = aim.point
        aim.move(to: CGPoint(x: 132, y: 111), time: 0.8)
        #expect(aim.point == CGPoint(x: pressed.x + 10, y: pressed.y + 10))
        #expect(!aim.dragDue(at: 2))
        #expect(aim.end() == .dragging)
    }

    @Test func nothingHappensBeforeAimingBegins() {
        var aim = PointerAim()
        aim.move(to: CGPoint(x: 5, y: 5), time: 1)
        aim.startDrag()
        #expect(aim.phase == .idle && aim.point == .zero && !aim.dragDue(at: 9))
    }
}
