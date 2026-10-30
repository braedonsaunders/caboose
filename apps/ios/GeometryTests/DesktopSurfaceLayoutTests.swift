import XCTest
import SwiftUI
import UIKit
import QuartzCore
@testable import Caboose
@testable import CabooseKit

@MainActor
final class DesktopSurfaceLayoutTests: XCTestCase {
    func testReattachedWindowAdoptsSameSizePictureAndNotifiesContainer() {
        let picture = CGSize(width: 1600, height: 1000)
        let first = RemoteWindow(id: 1, frame: CGRect(origin: .zero, size: picture),
                                 overrideRedirect: false, surface: WindowSurface())
        let second = RemoteWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 1600, height: 520),
                                  overrideRedirect: false, surface: WindowSurface())
        let content = RemoteWindowView(session: nil, window: first)
        var notifications: [CGSize] = []
        content.onPictureSizeChanged = { notifications.append($0) }
        // Exercise the same adoption entry point present() calls after nextDrawable.
        content.adoptPictureSize(picture)
        content.adoptPictureSize(picture)
        XCTAssertEqual(notifications, [picture])
        content.attach(second)
        XCTAssertEqual(second.presentationSize.height, 520)
        content.adoptPictureSize(picture)
        XCTAssertEqual(second.presentationSize, picture)
        XCTAssertEqual(notifications, [picture, picture])
        // Updating the same identity keeps the per-view size deduplication.
        content.attach(second)
        content.adoptPictureSize(picture)
        XCTAssertEqual(notifications, [picture, picture])
        content.attach(nil)
    }

    func testKeyboardSlotFitsRetainedPictureBeforeMetadataAndDecodeCatchUp() {
        let surface = WindowSurface()
        surface.resize(width: 1600, height: 1000)
        let remote = RemoteWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
                                  overrideRedirect: false, surface: surface)
        let content = RemoteWindowView(session: nil, window: remote)
        content.pixelsPerPoint = 2
        let tile = YardSurfaceView(content: content)
        tile.natural = CGSize(width: 800, height: 500)
        tile.stretch = true
        // Metadata arrives ahead of the replacement picture, as FramePipeline permits.
        remote.frame.size = CGSize(width: 1600, height: 520)
        XCTAssertEqual(remote.presentationSize, CGSize(width: 1600, height: 1000))
        for height in [500, 400, 300, 260, 300, 400, 500] {
            tile.frame = CGRect(x: 0, y: 0, width: 800, height: height)
            tile.setNeedsLayout()
            tile.layoutIfNeeded()
            XCTAssertEqual(content.frame.width / content.frame.height, 1.6, accuracy: 0.000001)
            XCTAssertEqual(content.transform.a, content.transform.d, accuracy: 0.000001)
            let localCenter = content.convert(CGPoint(x: content.frame.midX, y: content.frame.midY), from: tile)
            XCTAssertEqual(content.pixelPoint(localCenter).x, 800, accuracy: 0.000001)
            XCTAssertEqual(content.pixelPoint(localCenter).y, 260, accuracy: 0.000001)
            XCTAssertEqual(content.layer.contentsGravity, .resizeAspect)
        }
        // The same callback used immediately before Metal presents the new drawable.
        remote.adoptPictureSize(CGSize(width: 1600, height: 520))
        content.onPictureSizeChanged?(remote.presentationSize)
        tile.layoutIfNeeded()
        XCTAssertEqual(content.bounds.size, CGSize(width: 800, height: 260))
        XCTAssertEqual(content.frame.width / content.frame.height, 1600.0 / 520, accuracy: 0.000001)
        content.attach(nil)
    }

    func testHostedCardAndYardPropagateFullscreenCentering() throws {
        let model = AppModel(collection: .init(), startsConnections: false)
        let pixels = model.pixelsPerPoint
        let remote = RemoteWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 1200 * pixels, height: 800 * pixels),
                                  overrideRedirect: false, surface: WindowSurface())
        remote.isFullscreen = true
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for card in [false, true] {
            let surface = card
                ? AnyView(RemoteWindowCanvas(window: remote, keyboardVisible: false))
                : AnyView(YardSurface(window: remote, pixelsPerPoint: pixels, stretch: true, keyboard: false) {})
            host.rootView = AnyView(surface.frame(width: 400, height: 800).environment(model).ignoresSafeArea())
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let tile = try XCTUnwrap(descendants(host.view).compactMap { $0 as? YardSurfaceView }.first)
            tile.layoutIfNeeded()
            XCTAssertTrue(tile.fullscreen)
            XCTAssertEqual(tile.content.frame.midX, tile.bounds.midX, accuracy: 0.01)
            XCTAssertEqual(tile.content.frame.midY, tile.bounds.midY, accuracy: 0.01)
            XCTAssertEqual(tile.content.frame.width / tile.content.frame.height, 1.5, accuracy: 0.01)
            tile.content.attach(nil)
        }
    }

    func testFullscreenSurfaceCentersAndInvertsTouchWhileTileIsSettling() throws {
        let remote = RemoteWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                                  overrideRedirect: false, surface: WindowSurface())
        let content = RemoteWindowView(session: nil, window: remote)
        let tile = YardSurfaceView(content: content)
        tile.natural = remote.frame.size
        tile.fullscreen = true
        tile.stretch = true
        for viewport in [CGSize(width: 400, height: 800), CGSize(width: 800, height: 400)] {
            tile.frame = CGRect(origin: .zero, size: viewport)
            tile.setNeedsLayout()
            tile.layoutIfNeeded()
            let shown = DesktopGeometry.surfaceFrame(natural: remote.frame.size, available: viewport,
                                                      resizing: true, fullscreen: true)
            XCTAssertEqual(content.frame.minX, shown.minX, accuracy: 0.01)
            XCTAssertEqual(content.frame.minY, shown.minY, accuracy: 0.01)
            XCTAssertEqual(content.frame.width, shown.width, accuracy: 0.01)
            XCTAssertEqual(content.frame.height, shown.height, accuracy: 0.01)
            let center = content.convert(CGPoint(x: viewport.width / 2, y: viewport.height / 2), from: tile)
            XCTAssertEqual(center.x, 600, accuracy: 0.01)
            XCTAssertEqual(center.y, 400, accuracy: 0.01)
            if shown.minY > 0 {
                XCTAssertFalse(content.point(inside: content.convert(CGPoint(x: shown.midX, y: shown.minY - 1), from: tile), with: nil))
            }
        }
        // An unchanged fullscreen-to-ordinary transition must invalidate layout too.
        tile.stretch = false
        tile.fullscreen = false
        tile.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        tile.layoutIfNeeded()
        XCTAssertEqual(content.frame.minY, 0, accuracy: 0.01)
        content.attach(nil)
    }

    func testTileWithWideMinimumFillsTallViewportAfterCommit() throws {
        let viewport = CGSize(width: 500, height: 800)
        let committed = try XCTUnwrap(WindowSizePolicy.fitting(CGRect(origin: .zero, size: viewport),
            minimum: CGSize(width: 862, height: 600), maximum: nil, fullscreen: false))
        let remote = RemoteWindow(id: 1, frame: committed, overrideRedirect: false, surface: WindowSurface())
        let content = RemoteWindowView(session: nil, window: remote)
        let tile = YardSurfaceView(content: content)
        tile.natural = committed.size
        tile.frame = CGRect(origin: .zero, size: viewport)
        tile.setNeedsLayout()
        tile.layoutIfNeeded()
        XCTAssertEqual(content.frame.minX, 0, accuracy: 1)
        XCTAssertEqual(content.frame.minY, 0, accuracy: 1)
        XCTAssertEqual(content.frame.maxX, viewport.width, accuracy: 1)
        XCTAssertEqual(content.frame.maxY, viewport.height, accuracy: 1)
        // UIKit's inverse transform and the remote input geometry agree.
        let center = content.convert(CGPoint(x: viewport.width / 2, y: viewport.height / 2), from: tile)
        XCTAssertEqual(center.x, committed.width / 2, accuracy: 0.01)
        XCTAssertEqual(center.y, committed.height / 2, accuracy: 0.01)
        content.attach(nil)
    }

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
    func testAttachedWindowDivisionConversionIgnoresProbeViewport() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 656, height: 932))
        let probe = LaptopGeometryProbe.Probe(changed: { _ in })
        probe.frame = CGRect(x: 12, y: 24, width: 620, height: 500)
        window.addSubview(probe)
        defer { probe.stop(); probe.removeFromSuperview() }
        let measured = probe.physicalGeometry(division: CGRect(x: -12, y: 422, width: 656, height: 40))
        XCTAssertEqual(measured.hostSize, window.bounds.size)
        XCTAssertEqual(measured.physicalDivision, CGRect(x: 0, y: 446, width: 656, height: 40))
        probe.frame.size.height = 300 // keyboard/card viewport changes cannot change the physical mode
        XCTAssertEqual(probe.physicalGeometry(division: measured.division).physicalDivision, measured.physicalDivision)
        XCTAssertEqual(probe.physicalGeometry(division: measured.division).hostSize, measured.hostSize)
    }

    func testHostedUpperPanelKeepsMeasuredHingeBlackAcrossContentTransitions() throws {
        let size = CGSize(width: 656, height: 932)
        let division = CGRect(x: 0, y: 446, width: 656, height: 40)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        for keyboard in [CGFloat(0), 600] {
            for hasWindow in [true, false, true] {
                let frames = LaptopLayout.frames(size: size, division: division, keyboard: keyboard)
                host.rootView = AnyView(ZStack(alignment: .topLeading) {
                    Color(red: 0, green: 1, blue: 0)
                    LaptopUpperPanel(screen: frames.screen, division: division, active: true,
                                     size: size) {
                        if hasWindow { Color(red: 1, green: 0, blue: 0) }
                        else { Color.clear }
                    }
                }.frame(width: size.width, height: size.height).ignoresSafeArea())
                window.layoutIfNeeded()
                host.view.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let format = UIGraphicsImageRendererFormat()
                // Inspect native pixels: a 1x drawHierarchy snapshot resamples the
                // device's backing store and blends the exact hinge boundary rows.
                format.scale = window.screen.scale
                format.preferredRange = .standard
                let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let cg = try XCTUnwrap(rendered.cgImage)
                // Normalize the snapshot to known RGBA bytes before inspecting boundaries.
                let pixelWidth = cg.width, pixelHeight = cg.height
                var bytes = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
                try bytes.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                        bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.interpolationQuality = .none
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                }
                func pixel(_ y: Int) -> ArraySlice<UInt8> {
                    let xPixel = Int(100.5 * format.scale)
                    let yPixel = Int((CGFloat(y) + 0.5) * format.scale)
                    let offset = (yPixel * pixelWidth + xPixel) * 4
                    return bytes[offset..<(offset + 3)]
                }
                XCTAssertEqual(Array(pixel(Int(frames.screen.maxY) - 1)), hasWindow ? [255, 0, 0] : [0, 255, 0])
                XCTAssertEqual(Array(pixel(446)), [0, 0, 0])
                XCTAssertEqual(Array(pixel(485)), [0, 0, 0])
                XCTAssertEqual(Array(pixel(486)), [0, 255, 0]) // controls begin here
                if keyboard > 0 {
                    XCTAssertEqual(Array(pixel(400)), [0, 255, 0]) // keyboard gap is not a hinge
                }
            }
        }
    }

}
