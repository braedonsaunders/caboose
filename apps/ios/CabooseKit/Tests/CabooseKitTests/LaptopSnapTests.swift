import CoreGraphics
import Testing
@testable import CabooseKit

/// Laptop shows every window fitted into its snap, so its snap layouts are judged at
/// `TilePolicy.fittedScale`: the layouts that fit its upper screen are offered, not only
/// the whole screen.
struct LaptopSnapTests {
    /// An iPhone Duo's inner screen on its side in Laptop: the half above the hinge, at the
    /// phone desktop's scale for its width (`DesktopModel.deviceUI`).
    let area = CGRect(x: 0, y: 0, width: 951, height: 330)
    let ui: CGFloat = 951.0 / 1100
    let titleBar: CGFloat = 32

    private func required(minimum: CGSize? = nil) -> CGSize {
        TilePolicy.required(minimum: minimum, titleBar: titleBar, in: area.size,
                            floor: CGSize(width: TilePolicy.floor.width * ui, height: TilePolicy.floor.height * ui))
    }

    private func offered(fitted: Bool, minimum: CGSize? = nil) -> Set<FreeDesktopLayout.Snap> {
        let need = fitted ? TilePolicy.fitted(required(minimum: minimum)) : required(minimum: minimum)
        return Set(FreeDesktopLayout.Snap.allCases.filter {
            TilePolicy.allows(FreeDesktopLayout.rect(for: $0, in: area).size, required: need, in: area.size)
        })
    }

    @Test func theDuosUpperScreenOffersItsHalvesInLaptop() {
        #expect(offered(fitted: false) == [.maximized, .leftTwoThirds, .rightTwoThirds])
        // Quarters would be 165 points high and thirds 317 wide: too small even scaled.
        #expect(offered(fitted: true) == [.maximized, .left, .right, .leftTwoThirds, .rightTwoThirds])
    }

    @Test func aFittedSnapPaletteEnablesTheLayoutsThatFit() {
        let need = TilePolicy.fitted(required())
        let palette = FreeDesktopLayout.SnapPalette(in: area, scale: ui) { snap, _ in
            TilePolicy.allows(FreeDesktopLayout.rect(for: snap, in: area).size, required: need, in: area.size)
        }
        let enabled = Set(palette.regions.filter(\.enabled).map(\.snap))
        #expect(enabled == [.maximized, .left, .right, .leftTwoThirds, .rightTwoThirds])
    }

    @Test func aFittedTileIsNeverShownBelowThreeQuarters() {
        let need = required()
        for snap in offered(fitted: true) {
            let tile = FreeDesktopLayout.rect(for: snap, in: area).size
            let scale = min(1, tile.width / need.width, tile.height / need.height)
            #expect(scale >= TilePolicy.fittedScale - 0.01, "\(snap)")
        }
    }

    @Test func aSnappedWindowIsLaidOutAtAUsableSizeAtItsSnapsShape() {
        // The left half of the Duo's upper screen, at 2 pixels a point, below the title bar.
        let half = CGRect(x: 0, y: 64, width: 668, height: 816)
        let usable = CGSize(width: 403 * 2, height: (288 - titleBar) * 2)
        let minimum = LaptopFill.snappedMinimum(nil, usable: usable)
        #expect(minimum == CGSize(width: 806, height: 512))
        let laid = LaptopFill.layout(half, snap: .left, screen: CGRect(x: 0, y: 64, width: 1338, height: 816),
                                     minimum: minimum, maximum: nil)
        #expect(laid != nil)
        if let frame = laid?.frame {
            #expect(frame.width >= 806 && frame.height >= 512)
            #expect(abs(frame.width / frame.height - half.width / half.height) < 0.01)
        }
        // A window's own larger minimum wins on its axis; no limits at all leaves the usable size.
        #expect(LaptopFill.snappedMinimum(CGSize(width: 1000, height: 100), usable: usable) == CGSize(width: 1000, height: 512))
        #expect(LaptopFill.snappedMinimum(CGSize(width: CGFloat.nan, height: -1), usable: .zero) == .zero)
    }
}
