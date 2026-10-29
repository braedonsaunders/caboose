import Foundation
import Testing
@testable import CabooseKit

struct DirectPointerDragTests {
    @Test func strokeStartsWhereTheFingerLanded() {
        var drag = DirectPointerDrag()
        let point = CGPoint(x: 30, y: 40), origin = CGPoint(x: 20, y: 20)
        #expect(drag.begin(at: point, translation: CGPoint(x: 10, y: 20)) ==
                [.move(origin), .button(origin, pressed: true), .move(point)])
        #expect(drag.move(to: .zero) == [.move(.zero)])
        #expect(drag.end(at: point) == [.move(point), .button(point, pressed: false)])
        #expect(drag.cancel().isEmpty)
    }

    @Test func cancellationReleasesOnceAndIgnoresLateMovement() {
        var drag = DirectPointerDrag()
        let point = CGPoint(x: 30, y: 40)
        _ = drag.begin(at: .zero, translation: .zero)
        _ = drag.move(to: point)
        #expect(drag.cancel() == [.button(point, pressed: false)])
        #expect(drag.move(to: .zero).isEmpty)
        #expect(drag.end(at: .zero).isEmpty)
        #expect(drag.cancel().isEmpty)
    }

    @Test func replacingAStrokeReleasesItsOldButton() {
        var drag = DirectPointerDrag()
        _ = drag.begin(at: .zero, translation: .zero)
        let point = CGPoint(x: 10, y: 10)
        #expect(drag.begin(at: point, translation: .zero) ==
                [.button(.zero, pressed: false), .move(point), .button(point, pressed: true), .move(point)])
    }
}
