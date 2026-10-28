import CoreGraphics
import Testing
@testable import CabooseKit

struct VideoLayerGeometryTests {
    @Test func resizedPictureAndOverlayHaveTheSameMapping() throws {
        // An optimistic configure already resized the view; the old 500×678 picture
        // and its video metadata are still on screen in the 466-pixel-wide viewport.
        let geometry = try #require(VideoLayerGeometry(
            rect: CGRect(x: 20, y: 200, width: 460, height: 240), clip: nil,
            surfaceSize: CGSize(width: 500, height: 678),
            bounds: CGRect(x: 0, y: 0, width: 233, height: 339)))
        #expect(abs(geometry.container.minX - 9.32) < 0.0001)
        #expect(abs(geometry.container.width - 214.36) < 0.0001)
        #expect(geometry.container.minY == 100)
        #expect(geometry.picture.origin == .zero)
    }

    @Test func scrollClipKeepsWholePictureScaleAndCutsToWindow() throws {
        let geometry = try #require(VideoLayerGeometry(
            rect: CGRect(x: -40, y: -20, width: 600, height: 400),
            clip: CGRect(x: -10, y: 50, width: 520, height: 250),
            surfaceSize: CGSize(width: 500, height: 678),
            bounds: CGRect(x: 10, y: 15, width: 250, height: 339)))
        #expect(geometry.container == CGRect(x: 10, y: 40, width: 250, height: 125))
        #expect(geometry.picture == CGRect(x: -20, y: -35, width: 300, height: 200))
    }

    @Test func yardTransformAppliesOnceToBothLayers() throws {
        let natural = CGSize(width: 250, height: 339)
        let geometry = try #require(VideoLayerGeometry(
            rect: CGRect(x: 100, y: 200, width: 300, height: 200), clip: nil,
            surfaceSize: CGSize(width: 500, height: 678), bounds: CGRect(origin: .zero, size: natural)))
        for resizing in [false, true] {
            let shown = DesktopGeometry.surfaceFrame(natural: natural,
                available: CGSize(width: 190, height: 600), resizing: resizing)
            let videoTop = shown.minY + geometry.container.minY * shown.height / natural.height
            let pictureTop = shown.minY + 200 * shown.height / 678
            #expect(abs(videoTop - pictureTop) < 0.0001)
        }
    }

    @Test func emptyOrFullyOffscreenVideoIsAbsent() {
        for rect in [CGRect.zero, CGRect(x: 600, y: 0, width: 100, height: 100)] {
            #expect(VideoLayerGeometry(rect: rect, clip: nil,
                surfaceSize: CGSize(width: 500, height: 678),
                bounds: CGRect(x: 0, y: 0, width: 250, height: 339)) == nil)
        }
    }
}
