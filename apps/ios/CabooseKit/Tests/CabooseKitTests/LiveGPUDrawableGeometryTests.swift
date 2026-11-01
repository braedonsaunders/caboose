import CoreGraphics
import XCTest
@testable import CabooseKit

final class LiveGPUDrawableGeometryTests: XCTestCase {
    func testFittingAndPhoneScaleDoNotChangeServerPixelExtent() {
        for bounds in [CGSize(width: 320, height: 240), CGSize(width: 480, height: 900), CGSize(width: 960, height: 720)] {
            XCTAssertEqual(LiveGPUDrawableGeometry.extent(serverPixels: CGSize(width: 640, height: 480), visibleBounds: bounds), CGSize(width: 640, height: 480))
        }
    }
    func testKnownResizeMustBeConfirmedBeforeBinding() {
        let old = CGSize(width: 932, height: 1356), requested = CGSize(width: 763, height: 1116)
        let view = CGSize(width: 381.5, height: 558)
        XCTAssertNil(LiveGPUDrawableGeometry.extent(serverPixels: old, visibleBounds: view, requestedPixels: requested))
        XCTAssertEqual(LiveGPUDrawableGeometry.extent(serverPixels: requested, visibleBounds: view, requestedPixels: requested), requested)
    }
    func testRequestUsesAssignedOutputQuantization() {
        XCTAssertEqual(LiveGPUDrawableGeometry.quantizedRequest(CGSize(width: 763, height: 1116), scale: 2), CGSize(width: 764, height: 1116))
        for dpi in [138.0, 180.0] {
            let fractional = LiveGPUDrawableGeometry.quantizedRequest(CGSize(width: 764, height: 1116), scale: dpi / 96.0)
            XCTAssertEqual(fractional, CGSize(width: 763, height: 1116))
        }
        XCTAssertNil(LiveGPUDrawableGeometry.quantizedRequest(CGSize(width: 764, height: 1116), scale: .nan))
        XCTAssertNil(LiveGPUDrawableGeometry.quantizedRequest(CGSize(width: 764, height: 1116), scale: 0))
    }
    func testNewServerPixelSizeChangesDrawable() {
        XCTAssertEqual(LiveGPUDrawableGeometry.extent(serverPixels: CGSize(width: 1280, height: 960), visibleBounds: CGSize(width: 320, height: 240)), CGSize(width: 1280, height: 960))
    }
    func testMissingOrInvalidGeometryDoesNotInventExtent() {
        for size in [CGSize.zero, CGSize(width: -1, height: 480), CGSize(width: 640.5, height: 480), CGSize(width: CGFloat.infinity, height: 480), CGSize(width: CGFloat.nan, height: 480), CGSize(width: CGFloat(UInt32.max) + 1, height: 480)] {
            XCTAssertNil(LiveGPUDrawableGeometry.extent(serverPixels: size, visibleBounds: CGSize(width: 320, height: 240)))
        }
        XCTAssertNil(LiveGPUDrawableGeometry.extent(serverPixels: CGSize(width: 640, height: 480), visibleBounds: .zero))
    }
    func testPictureOfTheWindowsShapeFillsIt() {
        let bounds = CGRect(x: 0, y: 0, width: 669, height: 456)
        XCTAssertEqual(LiveGPUDrawableGeometry.placement(picture: CGSize(width: 1338, height: 912), in: bounds, fill: false), bounds)
        // Rounding of the two sizes is not a shape.
        XCTAssertEqual(LiveGPUDrawableGeometry.placement(picture: CGSize(width: 1338, height: 911), in: bounds, fill: false), bounds)
    }
    func testKeptResolutionFitsTheGrownWindowCentred() {
        // A game kept at 1338x911 after a fold opened its window to 1902x1338 (951x669 pt).
        let bounds = CGRect(x: 0, y: 0, width: 951, height: 669)
        let placed = LiveGPUDrawableGeometry.placement(picture: CGSize(width: 1338, height: 911), in: bounds, fill: false)
        XCTAssertEqual(placed.width, 951, accuracy: 0.001)
        XCTAssertEqual(placed.height, 647.5, accuracy: 0.1)
        XCTAssertEqual(placed.midX, bounds.midX, accuracy: 0.001)
        XCTAssertEqual(placed.midY, bounds.midY, accuracy: 0.001)
        XCTAssertGreaterThan(placed.minY, 0)
    }
    func testTallPictureIsPillarboxed() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 450)
        let placed = LiveGPUDrawableGeometry.placement(picture: CGSize(width: 600, height: 900), in: bounds, fill: false)
        XCTAssertEqual(placed, CGRect(x: 260, y: 20, width: 300, height: 450))
    }
    func testFullScreenWindowFillsANearShapeAndLetterboxesAnotherShape() {
        let bounds = CGRect(x: 0, y: 0, width: 951, height: 669)
        XCTAssertEqual(LiveGPUDrawableGeometry.placement(picture: CGSize(width: 1338, height: 911), in: bounds, fill: true), bounds)
        // A 16:9 game on the unfolded screen keeps its shape, centred with bars, never stretched.
        let wide = LiveGPUDrawableGeometry.placement(picture: CGSize(width: 1920, height: 1080), in: bounds, fill: true)
        XCTAssertEqual(wide.width, 951, accuracy: 0.5)
        XCTAssertEqual(wide.height, 951 * 1080 / 1920, accuracy: 0.5)
        XCTAssertEqual(wide.midY, bounds.midY, accuracy: 0.5)
    }
    func testMissingPictureOrBoundsFillsWithoutInventingAShape() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(LiveGPUDrawableGeometry.placement(picture: .zero, in: bounds, fill: false), bounds)
        XCTAssertEqual(LiveGPUDrawableGeometry.placement(picture: CGSize(width: CGFloat.nan, height: 1), in: bounds, fill: false), bounds)
        XCTAssertEqual(LiveGPUDrawableGeometry.placement(picture: CGSize(width: 4, height: 3), in: .zero, fill: false), .zero)
    }
}

