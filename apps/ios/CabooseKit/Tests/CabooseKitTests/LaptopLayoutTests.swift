import CoreGraphics
import Testing
@testable import CabooseKit

struct LaptopLayoutTests {
    let size = CGSize(width: 680, height: 850)
    let horizontal = CGRect(x: 0, y: 410, width: 680, height: 30)

    @Test func onlyTablePostureAutomaticallySplits() {
        #expect(LaptopLayout.isActive(mode: .automatic, size: size, division: horizontal, partiallyOpen: true))
        #expect(!LaptopLayout.isActive(mode: .automatic, size: size, division: horizontal, partiallyOpen: false))
        #expect(!LaptopLayout.isActive(mode: .automatic, size: size, division: CGRect(x: 320, y: 0, width: 30, height: 850), partiallyOpen: true))
        #expect(!LaptopLayout.isActive(mode: .automatic, size: size, division: nil, partiallyOpen: true))
    }
    @Test func overrideAndSmallScreens() {
        #expect(LaptopLayout.isActive(mode: .laptop, size: size, division: nil, partiallyOpen: false))
        #expect(!LaptopLayout.isActive(mode: .tablet, size: size, division: horizontal, partiallyOpen: true))
        #expect(!LaptopLayout.isActive(mode: .laptop, size: CGSize(width: 680, height: 350), division: nil, partiallyOpen: true))
    }
    @Test func actualFoldIsReservedOnce() {
        let frames = LaptopLayout.frames(size: size, division: horizontal, keyboard: 0)
        #expect(frames.screen.maxY == 402)
        #expect(frames.controls.minY == 448)
        #expect(frames.controls.maxY == size.height)
    }
    @Test func keyboardNeverCoversUpperAppOrProducesNegativeControls() {
        for keyboard in [CGFloat(0), 300, 470, 900] {
            let frames = LaptopLayout.frames(size: size, division: horizontal, keyboard: keyboard)
            #expect(frames.screen.maxY <= max(0, size.height - keyboard))
            #expect(frames.controls.height >= 0)
            #expect(frames.screen.maxY <= frames.controls.minY)
        }
    }
    @Test func manualFlatModeHasSameSplitAfterKeyboardRoundTrip() {
        let first = LaptopLayout.frames(size: size, division: nil, keyboard: 0)
        _ = LaptopLayout.frames(size: size, division: nil, keyboard: 350)
        #expect(LaptopLayout.frames(size: size, division: nil, keyboard: 0) == first)
    }
}
