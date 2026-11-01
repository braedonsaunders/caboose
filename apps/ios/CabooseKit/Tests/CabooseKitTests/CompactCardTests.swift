import CoreGraphics
import Testing
@testable import CabooseKit

/// Small fixed-size windows show as a card of their own size, not a full tile.
struct CompactCardTests {
    let tile = CGSize(width: 550, height: 800)

    @Test func cappedUpdaterIsACard() {
        // Steam's updater: about 295 × 95 points with a maximum of its own size.
        let size = CGSize(width: 295, height: 95)
        #expect(DesktopGeometry.compactCard(natural: size, maximum: size, available: tile, settling: false, fullscreen: false) == size)
    }

    @Test func aWindowThatKeptItsSmallSizeIsACardOnceSettled() {
        let size = CGSize(width: 150, height: 90)
        #expect(DesktopGeometry.compactCard(natural: size, maximum: nil, available: tile, settling: true, fullscreen: false) == nil)
        #expect(DesktopGeometry.compactCard(natural: size, maximum: nil, available: tile, settling: false, fullscreen: false)
                == CGSize(width: 220, height: 90))
    }

    @Test func ordinaryWindowsKeepTheirTile() {
        #expect(DesktopGeometry.compactCard(natural: tile, maximum: nil, available: tile, settling: false, fullscreen: false) == nil)
        // Narrower but full height (a minimum-width app in a narrow column) stays a tile.
        #expect(DesktopGeometry.compactCard(natural: CGSize(width: 300, height: 800), maximum: nil, available: tile, settling: false, fullscreen: false) == nil)
        #expect(DesktopGeometry.compactCard(natural: CGSize(width: 100, height: 100), maximum: nil, available: tile, settling: false, fullscreen: true) == nil)
    }
}
