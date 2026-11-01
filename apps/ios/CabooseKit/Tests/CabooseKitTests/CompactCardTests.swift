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

    @Test func aDialogWiderThanTheTileShrinksWithItsShape() {
        // Steam's GTK error dialog, 546 × 390 with a maximum of its own size, in a 466-wide tile:
        // the card is the picture scaled to the tile's width, with no band below it.
        let size = CGSize(width: 546, height: 390), narrow = CGSize(width: 466, height: 678)
        let card = DesktopGeometry.compactCard(natural: size, maximum: size, available: narrow, settling: false, fullscreen: false)
        #expect(card?.width == 466)
        #expect(abs((card?.height ?? 0) - 390 * 466 / 546) < 0.001)
    }

    @Test func ordinaryWindowsKeepTheirTile() {
        #expect(DesktopGeometry.compactCard(natural: tile, maximum: nil, available: tile, settling: false, fullscreen: false) == nil)
        // Narrower but full height (a minimum-width app in a narrow column) stays a tile.
        #expect(DesktopGeometry.compactCard(natural: CGSize(width: 300, height: 800), maximum: nil, available: tile, settling: false, fullscreen: false) == nil)
        #expect(DesktopGeometry.compactCard(natural: CGSize(width: 100, height: 100), maximum: nil, available: tile, settling: false, fullscreen: true) == nil)
    }
}
