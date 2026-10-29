import CoreGraphics
import Testing
@testable import CabooseKit

/// ⌥Tab's strip: what it opens on, how it moves, what closing windows do, and its size.
struct QuickSwitchTests {
    @Test func aPressAndReleaseGoesBackToThePreviousWindow() {
        var quick = QuickSwitch()
        quick.open([4, 9, 2])
        #expect(quick.isOpen && quick.selection == 9)
        #expect(quick.close() == 9)
        #expect(!quick.isOpen && quick.windows.isEmpty)
    }

    @Test func tabMovesOnAndShiftMovesBackWrapping() {
        var quick = QuickSwitch()
        quick.open([4, 9, 2])
        quick.advance()
        #expect(quick.selection == 2)
        quick.advance()
        #expect(quick.selection == 4)
        quick.advance(reverse: true)
        #expect(quick.selection == 2)
        // ⇧⌥Tab opens on the least recent.
        quick.open([4, 9, 2], reverse: true)
        #expect(quick.selection == 2)
    }

    @Test func oneWindowOrNone() {
        var quick = QuickSwitch()
        quick.open([7])
        #expect(quick.selection == 7)
        quick.advance()
        #expect(quick.selection == 7)
        quick.open([])
        #expect(!quick.isOpen)
    }

    @Test func closedWindowsLeaveWithoutMovingTheSelection() {
        var quick = QuickSwitch()
        quick.open([1, 2, 3, 4])
        quick.advance()  // 3
        quick.prune(keeping: [2, 3, 4])
        #expect(quick.windows == [2, 3, 4] && quick.selection == 3)
        // The selected window closes: the next one takes its place.
        quick.prune(keeping: [2, 4])
        #expect(quick.selection == 4)
        quick.select(2)
        #expect(quick.selection == 2)
        quick.prune(keeping: [])
        #expect(!quick.isOpen)
    }

    @Test func theStripShrinksToFitThenShowsAroundTheSelection() {
        var quick = QuickSwitch()
        quick.open(Array(0..<4))
        let roomy = quick.strip(height: 800)
        #expect(roomy.item == 64 && roomy.visible == 0..<4)
        #expect(roomy.frame(of: 1) == CGRect(x: 10, y: 82, width: 64, height: 64))
        #expect(roomy.size == CGSize(width: 84, height: 4 * 64 + 3 * 8 + 20))
        quick.open(Array(0..<10))
        let tight = quick.strip(height: 500)
        #expect(tight.item == 40 && tight.visible == 0..<10)
        quick.open(Array(0..<30))
        for _ in 0..<19 { quick.advance() }  // the 21st window
        let crowded = quick.strip(height: 500)
        #expect(crowded.item == 36 && crowded.visible.count == 11 && crowded.visible.contains(20))
        #expect(crowded.size.height <= 500)
        #expect(crowded.frame(of: 0) == nil)
    }

    @Test func aFingerCanSelectNothingAndLetGoSafely() {
        var quick = QuickSwitch()
        quick.present([4, 9, 2])
        #expect(quick.isOpen && quick.selection == nil)
        quick.select(2)
        #expect(quick.selection == 2)
        quick.deselect()
        #expect(quick.isOpen && quick.selection == nil)
        // A window closing with nothing selected only leaves the strip.
        quick.prune(keeping: [4, 2])
        #expect(quick.windows == [4, 2] && quick.selection == nil)
        // A key takes over from the first window.
        quick.advance()
        #expect(quick.selection == 4)
        quick.deselect()
        #expect(quick.close() == nil && !quick.isOpen)
    }

    @Test func rowsAnswerAcrossTheirShareOfTheSpacing() {
        var quick = QuickSwitch()
        quick.open([1, 2, 3])
        let strip = quick.strip(height: 800)
        // Rows of 64 from y 10, every 72.
        #expect(strip.index(atY: 5) == nil)
        #expect(strip.index(atY: 6) == 0)
        #expect(strip.index(atY: 77.9) == 0)
        #expect(strip.index(atY: 78) == 1)
        #expect(strip.index(atY: 221) == 2)
        #expect(strip.index(atY: 223) == nil)
        #expect(strip.index(atY: -40) == nil)
    }
}
