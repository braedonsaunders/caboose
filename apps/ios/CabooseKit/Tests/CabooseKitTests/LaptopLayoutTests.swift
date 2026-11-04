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
        #expect(frames.screen.maxY == 410)
        #expect(frames.controls.minY == 440)
        #expect(frames.controls.maxY == size.height)
    }
    @Test func keyboardNeverCoversUpperAppOrProducesNegativeControls() {
        for keyboard in [CGFloat(0), 300, 470, 900] {
            let frames = LaptopLayout.frames(size: size, division: horizontal, keyboard: keyboard)
            #expect(frames.screen.maxY <= max(0, size.height - keyboard))
            #expect(frames.controls.height >= 0)
            #expect(frames.controls.minY == horizontal.maxY)
            #expect(frames.screen.maxY <= frames.controls.minY)
        }
    }
    @Test func comboKeepsTrackpadAboveFullWidthKeyboard() {
        for height in [CGFloat(240), 360, 480] {
            let trackpad = LaptopLayout.comboTrackpadHeight(height)
            #expect(trackpad == height / 3)
            #expect(height - trackpad == height * 2 / 3)
        }
        #expect(LaptopLayout.comboTrackpadHeight(-1) == 0)
        #expect(LaptopLayout.comboTrackpadHeight(.infinity) == 0)
    }
    @Test func eachInputSharesTheControlsItsWay() {
        #expect(LaptopLayout.trackpadHeight(.trackpad, available: 360) == 360)
        #expect(LaptopLayout.trackpadHeight(.combo, available: 360) == 120)
        // Keyboard mode is Laptop's own keyboard filling the lower half, header included.
        #expect(LaptopLayout.trackpadHeight(.keyboard, available: 360) == 0)
        #expect(LaptopLayout.trackpadHeight(.trackpad, available: -5) == 0)
        #expect(LaptopLayout.trackpadHeight(.trackpad, available: .infinity) == 0)
        #expect(LaptopLayout.Input.keyboard.showsKeyboard && LaptopLayout.Input.combo.showsKeyboard)
        #expect(!LaptopLayout.Input.trackpad.showsKeyboard)
    }
    @Test func manualFlatModeHasSameSplitAfterKeyboardRoundTrip() {
        let first = LaptopLayout.frames(size: size, division: nil, keyboard: 0)
        _ = LaptopLayout.frames(size: size, division: nil, keyboard: 350)
        #expect(LaptopLayout.frames(size: size, division: nil, keyboard: 0) == first)
    }
}

/// Laptop's upper screen on a fold whose top edge falls between device pixels.
@Suite struct LaptopFractionalPanelTests {
    @Test func displayCoversTheWholeUpperPanel() throws {
        for height in [455.5, 455.33, 455.67, 456.0, 455.999_9] as [CGFloat] {
            let pixels = try #require(MonitorPolicy.pixels(Double(height), scale: 2))
            #expect(CGFloat(pixels) / 2 >= height - 0.001, "\(height) pt is covered")
            #expect(CGFloat(pixels) / 2 < height + 0.5, "by less than a pixel more")
        }
        #expect(MonitorPolicy.pixels(669, scale: 2) == 1338)
        #expect(MonitorPolicy.pixels(0, scale: 2) == nil)
    }

    @Test func fullscreenPictureFillsTheUpperPanel() {
        for height in [455.5, 455.33, 455.67] as [CGFloat] {
            let panel = CGSize(width: 669, height: height)
            let pixels = CGFloat(MonitorPolicy.pixels(Double(height), scale: 2) ?? 0)
            let natural = CGSize(width: 669, height: pixels / 2)
            let shown = DesktopGeometry.surfaceFrame(natural: natural, available: panel, resizing: false, fullscreen: true)
            #expect(shown == CGRect(origin: .zero, size: panel))
        }
    }

    @Test func divisionStartsAtThePixelRowOfTheFold() {
        let division = CGRect(x: 0, y: 455.67, width: 669, height: 30)
        let top = LaptopLayout.divisionTop(division, scale: 3)
        #expect(top <= division.minY && division.minY - top < 1.0 / 3)
        #expect(abs((top * 3).rounded() - top * 3) < 0.0001)
        #expect(LaptopLayout.divisionTop(CGRect(x: 0, y: 456, width: 669, height: 30), scale: 2) == 456)
    }
}
