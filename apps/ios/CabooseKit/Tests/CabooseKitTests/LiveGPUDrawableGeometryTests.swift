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
    func testNewServerPixelSizeChangesDrawable() {
        XCTAssertEqual(LiveGPUDrawableGeometry.extent(serverPixels: CGSize(width: 1280, height: 960), visibleBounds: CGSize(width: 320, height: 240)), CGSize(width: 1280, height: 960))
    }
    func testMissingOrInvalidGeometryDoesNotInventExtent() {
        for size in [CGSize.zero, CGSize(width: -1, height: 480), CGSize(width: 640.5, height: 480), CGSize(width: CGFloat.infinity, height: 480), CGSize(width: CGFloat.nan, height: 480), CGSize(width: CGFloat(UInt32.max) + 1, height: 480)] {
            XCTAssertNil(LiveGPUDrawableGeometry.extent(serverPixels: size, visibleBounds: CGSize(width: 320, height: 240)))
        }
        XCTAssertNil(LiveGPUDrawableGeometry.extent(serverPixels: CGSize(width: 640, height: 480), visibleBounds: .zero))
    }
}
