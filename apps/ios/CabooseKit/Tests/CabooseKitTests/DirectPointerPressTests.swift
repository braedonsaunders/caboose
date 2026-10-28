import Foundation
import Testing
@testable import CabooseKit

struct DirectPointerPressTests {
    @Test func heldContextUsesOriginalTargetDespiteJitterAndFiresOnlyOnce() {
        var press = DirectPointerPress()
        press.begin(at: CGPoint(x: 50, y: 80), time: 1)
        press.move(to: CGPoint(x: 54, y: 82))
        #expect(press.context(at: 1.49) == nil)
        #expect(press.context(at: 1.5) == CGPoint(x: 50, y: 80))
        #expect(press.context(at: 2) == nil)
    }
    @Test func movementCannotReturnToTheOriginalPointToOpenContext() {
        var press = DirectPointerPress()
        press.begin(at: .zero, time: 0)
        press.move(to: CGPoint(x: 20, y: 0))
        press.move(to: .zero)
        #expect(press.context(at: 1) == nil)
    }
    @Test func cancelledOrMultifingerSequenceCannotOpenContext() {
        var press = DirectPointerPress()
        press.begin(at: .zero, time: 0)
        press.cancel()
        #expect(press.context(at: 1) == nil)
        press.begin(at: CGPoint(x: 20, y: 10), time: 2)
        #expect(press.context(at: 2.1) == nil)
        #expect(press.context(at: 2.6) == CGPoint(x: 20, y: 10))
    }
}
