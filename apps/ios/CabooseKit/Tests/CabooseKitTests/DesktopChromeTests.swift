import CoreGraphics
import Testing
@testable import CabooseKit

struct DesktopChromeTests {
    @Test func widePortraitOverridesWidthBasedAndSystemTabs() {
        // Open Duo and iPad portrait windows use compact controls in the dock.
        for size in [CGSize(width: 686, height: 980),
                     CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 1366)] {
            #expect(DesktopChrome.usesCompactPanel(size: size))
            #expect(!DesktopChrome.usesCompactPanel(size: CGSize(width: size.height, height: size.width)))
        }
    }

    @Test func closedPhoneKeepsItsNativeSidebar() {
        for width in [390.0, 402, 466, 599] {
            #expect(!DesktopChrome.usesCompactPanel(size: CGSize(width: width, height: 844)))
        }
        #expect(DesktopChrome.usesCompactPanel(size: CGSize(width: 600, height: 844)))
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
