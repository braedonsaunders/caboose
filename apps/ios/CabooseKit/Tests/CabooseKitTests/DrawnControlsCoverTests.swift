import CoreGraphics
import Testing
@testable import CabooseKit

/// The covers over the window controls an application draws itself.
@MainActor
struct DrawnControlsCoverTests {
    /// Obsidian's vault window lists its controls as three 44 × 30 rows at the right edge.
    let obsidian = [CGRect(x: 668, y: 0, width: 44, height: 30), CGRect(x: 712, y: 0, width: 44, height: 30),
                    CGRect(x: 756, y: 0, width: 44, height: 30)]

    @Test func neighboursFormOneRow() {
        #expect(DrawnControlsCover.rows(obsidian) == [CGRect(x: 668, y: 0, width: 132, height: 30)])
        let apart = [CGRect(x: 0, y: 0, width: 30, height: 30), CGRect(x: 770, y: 0, width: 30, height: 30)]
        #expect(DrawnControlsCover.rows(apart) == apart)
    }

    @Test func colourIsReadBesideTheRowTowardTheMiddle() {
        let right = DrawnControlsCover.rows(obsidian)[0]
        #expect(DrawnControlsCover.samplePoint(of: right, windowWidth: 800) == CGPoint(x: 665, y: 15))
        let left = CGRect(x: 0, y: 4, width: 60, height: 20)
        #expect(DrawnControlsCover.samplePoint(of: left, windowWidth: 800) == CGPoint(x: 63, y: 14))
    }

    @Test func pixelsByteOrder() {
        // Bytes 0x11 0x22 0x33 0xFF in memory: BGRA blue 0x11, RGBA red 0x11.
        let pixel: UInt32 = 0xFF33_2211
        let bgra = DrawnControlsCover.colour(pixel, bgra: true).components ?? []
        let rgba = DrawnControlsCover.colour(pixel, bgra: false).components ?? []
        #expect(abs(bgra[0] - 0x33 / 255.0) < 1e-6 && abs(bgra[2] - 0x11 / 255.0) < 1e-6)
        #expect(abs(rgba[0] - 0x11 / 255.0) < 1e-6 && abs(rgba[2] - 0x33 / 255.0) < 1e-6)
    }

    @Test func wireKindNine() {
        let target = TouchTarget(wire: [756, 0, 44, 30, 9])
        #expect(target?.kind == .windowControl)
    }
}
