import CoreGraphics
import Testing
@testable import CabooseKit

struct LocalZoomTests {
    let viewport = CGSize(width: 900, height: 1300)

    @Test func contentUnderTheFingersStaysUnderThem() {
        var zoom = LocalZoom(centroid: CGPoint(x: 300, y: 400), viewport: viewport, limits: 0.5 ... 4)
        zoom.pinch(scale: 2, centroid: CGPoint(x: 350, y: 380))
        // The point first under the fingers shows where the fingers are now.
        #expect(abs(300 * zoom.zoom + zoom.translation.x - 350) < 1e-9)
        #expect(abs(400 * zoom.zoom + zoom.translation.y - 380) < 1e-9)
    }

    @Test func pastTheLimitRubberBandsAndSettlesBack() {
        var zoom = LocalZoom(centroid: CGPoint(x: 450, y: 650), viewport: viewport, limits: 0.5 ... 3)
        zoom.pinch(scale: 6, centroid: CGPoint(x: 450, y: 650))
        #expect(zoom.zoom > 3 && zoom.zoom < 4)
        let settled = zoom.end(at: 0)
        #expect(settled.zoom == 3)
        zoom.tick(at: LocalZoom.settleDuration)
        #expect(zoom.phase == .waiting && zoom.zoom == 3)
    }

    @Test func zoomedInContentCoversTheViewport() {
        var zoom = LocalZoom(centroid: CGPoint(x: 10, y: 10), viewport: viewport, limits: 0.5 ... 4)
        zoom.pinch(scale: 2, centroid: CGPoint(x: 400, y: 500))
        let settled = zoom.end(at: 0)
        // No edge of the content pulled inside: translation within [extent (1 - z), 0].
        #expect(settled.translation.x <= 0 && settled.translation.x >= viewport.width * (1 - 2))
        #expect(settled.translation.y <= 0 && settled.translation.y >= viewport.height * (1 - 2))
    }

    @Test func theFocusReproducesTheTranslation() throws {
        let focus = try #require(LocalZoom.focus(zoom: 2.5, translation: CGPoint(x: -600, y: -900)))
        // A pure scale about the focus keeps it still.
        #expect(abs(focus.x * 2.5 + -600 - focus.x) < 1e-9)
        #expect(abs(focus.y * 2.5 + -900 - focus.y) < 1e-9)
        #expect(LocalZoom.focus(zoom: 1, translation: .zero) == nil)
    }
}
