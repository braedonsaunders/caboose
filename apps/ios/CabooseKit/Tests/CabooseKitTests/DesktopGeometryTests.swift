import CoreGraphics
import Testing
@testable import CabooseKit

struct DesktopGeometryTests {
    @Test func maximizedChromeStartsAtTopAndClearsDock() {
        // External display and device desktop, including a compact landscape stage.
        for (size, ui) in [(CGSize(width: 1920, height: 1080), 1.2),
                           (CGSize(width: 1024, height: 700), 0.93),
                           (CGSize(width: 610, height: 320), 0.72)] {
            let title = 30 * ui, dock = 76 * ui, inset = 10 * ui, gap = 8 * ui
            let frame = DesktopGeometry.maximizedFrame(size: size, titleBarHeight: title,
                                                       dockHeight: dock, dockBottomInset: inset, dockGap: gap)
            #expect(frame.minY == 0)
            #expect(frame.width == size.width)
            let contentBottom = frame.maxY + title
            #expect(abs(contentBottom - (size.height - dock - inset - gap)) < 0.001)
        }
    }

    @Test func resizingNeverCropsBrowserControls() {
        let tile = CGSize(width: 300, height: 700)
        let frame = DesktopGeometry.surfaceFrame(natural: CGSize(width: 1000, height: 600),
                                                available: tile, resizing: true)
        #expect(frame == CGRect(origin: .zero, size: tile))
    }

    @Test func minimumSizedWindowFitsWholeAtTop() {
        let frame = DesktopGeometry.surfaceFrame(natural: CGSize(width: 1000, height: 600),
                                                available: CGSize(width: 300, height: 700), resizing: false)
        #expect(frame == CGRect(x: 0, y: 0, width: 300, height: 180))
        let tall = DesktopGeometry.surfaceFrame(natural: CGSize(width: 400, height: 1000),
                                               available: CGSize(width: 300, height: 400), resizing: false)
        #expect(tall == CGRect(x: 70, y: 0, width: 160, height: 400))
    }
}
