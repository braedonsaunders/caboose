import XCTest
import SwiftUI
import UIKit
import QuartzCore
@testable import Caboose
@testable import CabooseKit

@MainActor
final class DesktopSurfaceLayoutTests: XCTestCase {
    /// This hosts the production representable, rather than testing the fit formula.
    /// A newer remote aspect ratio must not refit inside the previous parent rectangle.
    func testStaleParentBoundsAndNewCommittedSizeHaveNoSecondFit() throws {
        let remote = RemoteWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 1680, height: 1060),
                                  overrideRedirect: false, surface: WindowSurface())
        var shown = CGSize(width: 840, height: 530)
        func content() -> AnyView {
            AnyView(RemoteWindowSurface(window: remote, pixelsPerPoint: 2, pacer: nil, showsVideo: false)
                .frame(width: shown.width, height: shown.height))
        }
        let host = UIHostingController(rootView: content())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1000, height: 900))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func layout() throws -> RemoteWindowView {
            host.rootView = content()
            host.view.setNeedsLayout()
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let views = descendants(host.view).compactMap { $0 as? RemoteWindowView }
            XCTAssertEqual(views.count, 1)
            let surface = try XCTUnwrap(views.first)
            surface.layoutIfNeeded()
            XCTAssertEqual(surface.bounds.size.width, shown.width, accuracy: 0.01)
            XCTAssertEqual(surface.bounds.size.height, shown.height, accuracy: 0.01)
            XCTAssertEqual(surface.transform, .identity)
            XCTAssertEqual(surface.layer.contentsGravity, .resize)
            XCTAssertFalse(descendants(host.view).contains { $0 is YardSurfaceView })
            // Text drops and pointer positions invert exactly this shown rectangle.
            let map = DesktopGeometry.SurfaceMapping(shown: CGRect(origin: .zero, size: surface.bounds.size), remote: remote.frame.size)
            XCTAssertEqual(map.point(CGPoint(x: shown.width / 2, y: shown.height / 2)),
                           CGPoint(x: remote.frame.width / 2, y: remote.frame.height / 2))
            return surface
        }
        let first = try layout()
        remote.frame.size = CGSize(width: 1680, height: 1180)
        XCTAssertTrue(try layout() === first) // old 840x530 parent, new 840x590 natural size
        shown = CGSize(width: 840, height: 590)
        XCTAssertTrue(try layout() === first) // parent catches up, without an inner transform
        remote.frame.size = CGSize(width: 1060, height: 1680)
        _ = try layout() // rotation arriving before its parent proposal
        shown = CGSize(width: 530, height: 840)
        _ = try layout()
        first.attach(nil)
    }
}
