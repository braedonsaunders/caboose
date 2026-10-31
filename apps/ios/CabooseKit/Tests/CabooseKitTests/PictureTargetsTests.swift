import Foundation
import Testing
@testable import CabooseKit

@Suite struct PictureTargetsTests {
    /// A grey 100 × 80 picture with an 8 × 8 dark icon at (20, 20), a light 30 × 12 button
    /// face at (50, 40) and a bar across the bottom.
    func picture() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 100 * 80 * 4)
        func fill(_ x0: Int, _ y0: Int, _ w: Int, _ h: Int, _ v: UInt8) {
            for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { let i = (y * 100 + x) * 4; bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255 } }
        }
        fill(0, 0, 100, 80, 128)
        fill(20, 20, 8, 8, 20)
        fill(50, 40, 30, 12, 230)
        fill(0, 70, 100, 4, 0)
        return bytes
    }

    func find(_ point: CGPoint, radius: Int) -> [CGRect] {
        picture().withUnsafeBytes {
            PictureTargets.find(in: $0, width: 100, height: 80, bytesPerRow: 400, around: point, radius: radius).map(\.rect)
        }
    }

    @Test func compactShapesNearTheTouchAreTargets() {
        let found = find(CGPoint(x: 45, y: 35), radius: 40)
        #expect(found.contains(CGRect(x: 17, y: 17, width: 14, height: 14)))
        #expect(found.contains(CGRect(x: 47, y: 37, width: 36, height: 18)))
        // The bar runs out of the area looked at: the window's furniture, not a control.
        #expect(found.count == 2)
    }

    @Test func aFlatAreaHasNone() {
        #expect(find(CGPoint(x: 80, y: 10), radius: 8).isEmpty)
    }

    @Test func badInputsFindNothing() {
        #expect(find(CGPoint(x: CGFloat.nan, y: 10), radius: 20).isEmpty)
        #expect(find(CGPoint(x: 10, y: 10), radius: 1).isEmpty)
    }
}
