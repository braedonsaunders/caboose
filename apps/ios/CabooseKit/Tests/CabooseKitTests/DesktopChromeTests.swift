import CoreGraphics
import Testing
@testable import CabooseKit

struct DesktopChromeTests {
    @Test func portraitOverridesWidthBasedAndSystemTabs() {
        // Closed phone, open Duo, and both iPad sizes must use the same chrome.
        for size in [CGSize(width: 390, height: 844), CGSize(width: 686, height: 980),
                     CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 1366)] {
            #expect(DesktopChrome.usesCompactPanel(size: size))
            #expect(!DesktopChrome.usesCompactPanel(size: CGSize(width: size.height, height: size.width)))
        }
    }

    @Test func squareWindowKeepsCompactControls() {
        #expect(DesktopChrome.usesCompactPanel(size: CGSize(width: 800, height: 800)))
    }

    @Test func unknownOrInvalidWindowDoesNotSelectPortrait() {
        for size in [CGSize.zero, CGSize(width: 0, height: 844),
                     CGSize(width: -1, height: 844), CGSize(width: 390, height: CGFloat.infinity),
                     CGSize(width: CGFloat.nan, height: 844)] {
            #expect(!DesktopChrome.usesCompactPanel(size: size))
        }
    }
}
