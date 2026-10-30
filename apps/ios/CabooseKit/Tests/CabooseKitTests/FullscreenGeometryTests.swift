import CoreGraphics
import Testing
@testable import CabooseKit

struct FullscreenGeometryTests {
    @Test func monitorChangesNeverReplaceOrdinaryRestoreGeometry() {
        var geometry = FullscreenGeometry()
        let ordinary = CGRect(x: 40, y: 60, width: 800, height: 600)
        let initial = geometry.observe(.init(frame: ordinary, fullscreen: false))
        #expect(initial == nil)
        for (index, size) in [CGSize(width: 1886, height: 1886), CGSize(width: 3840, height: 2160)].enumerated() {
            let request = geometry.observe(.init(frame: CGRect(origin: .zero, size: size), fullscreen: true))
            #expect(request == nil)
            #expect(geometry.ordinary == ordinary)
            #expect(geometry.entered == (index == 0))
        }
        let restore = geometry.observe(.init(frame: CGRect(x: 0, y: 0, width: 3840, height: 2160), fullscreen: false))
        #expect(restore == ordinary)
        let committed = geometry.observe(.init(frame: ordinary, fullscreen: false))
        #expect(committed == nil)
        #expect(!geometry.entered)
    }

    @Test func relativeScrollUsesTheSameScaleAndMappingChangesCancelItsSnapshot() {
        let mapping = DesktopGeometry.SurfaceMapping(shown: CGRect(x: 20, y: 30, width: 600, height: 400),
                                                     remote: CGSize(width: 2400, height: 1600))
        #expect(mapping.delta(CGPoint(x: 3, y: -5)) == CGPoint(x: 12, y: -20))
        #expect(mapping.point(CGPoint(x: 23, y: 35)) == CGPoint(x: 12, y: 20))
        let resized = DesktopGeometry.SurfaceMapping(shown: CGRect(x: 20, y: 30, width: 300, height: 200), remote: mapping.remote)
        #expect(mapping != resized)
        let committed = DesktopGeometry.SurfaceMapping(shown: mapping.shown, remote: CGSize(width: 1200, height: 800))
        #expect(mapping != committed)
    }

    @Test func firstSeenFullscreenDoesNotInventARestoreSize() {
        var geometry = FullscreenGeometry()
        let frame = CGRect(x: 0, y: 0, width: 1800, height: 1600)
        _ = geometry.observe(.init(frame: frame, fullscreen: true))
        let request = geometry.observe(.init(frame: frame, fullscreen: false))
        #expect(request == nil)
        #expect(geometry.ordinary == frame)
    }

    @Test func fullscreenPointerAndTouchGeometryMatchesRotatedAndKeyboardViewports() {
        let remote = CGSize(width: 2400, height: 1600)
        let natural = CGSize(width: remote.width / 2, height: remote.height / 2)
        for viewport in [CGSize(width: 531, height: 943), CGSize(width: 531, height: 500),
                         CGSize(width: 1102, height: 851), CGSize(width: 851, height: 1102)] {
            let shown = DesktopGeometry.surfaceFrame(natural: natural, available: viewport, resizing: false, fullscreen: true)
            #expect(abs(shown.midX - viewport.width / 2) < 0.001)
            #expect(abs(shown.midY - viewport.height / 2) < 0.001)
            // A settling tile/cover drag cannot stretch an app-requested fullscreen picture.
            #expect(DesktopGeometry.surfaceFrame(natural: natural, available: viewport, resizing: true,
                                                 fullscreen: true) == shown)
            let center = DesktopGeometry.remotePoint(CGPoint(x: shown.midX, y: shown.midY), shown: shown, remote: remote)
            #expect(abs((center?.x ?? 0) - 1200) < 0.001)
            #expect(abs((center?.y ?? 0) - 800) < 0.001)
            #expect(DesktopGeometry.remotePoint(CGPoint(x: shown.minX, y: shown.minY), shown: shown, remote: remote) == .zero)
            let below = CGPoint(x: shown.midX, y: shown.maxY + 1)
            #expect(DesktopGeometry.remotePoint(below, shown: shown, remote: remote) == nil)
            let release = DesktopGeometry.remotePoint(below, shown: shown, remote: remote, captured: true)
            #expect(release == CGPoint(x: 1200, y: 1600))
        }
    }

    @Test func fullscreenPortraitLetterboxingAndPopupShareCenteredRoot() throws {
        let remote = CGSize(width: 1200, height: 800)
        let viewport = CGSize(width: 400, height: 800)
        let root = DesktopGeometry.surfaceFrame(natural: remote, available: viewport, resizing: false, fullscreen: true)
        #expect(abs(root.minY - 800.0 / 3) < 0.001)
        let mapping = DesktopGeometry.SurfaceMapping(shown: root, remote: remote)
        #expect(mapping.point(CGPoint(x: 200, y: root.minY - 1)) == nil)
        #expect(mapping.point(CGPoint(x: 200, y: root.maxY + 1)) == nil)
        #expect(mapping.point(CGPoint(x: 200, y: 400)) == CGPoint(x: 600, y: 400))
        let frames = DesktopGeometry.popupFrames(windows: [
            1: .init(frame: CGRect(origin: .zero, size: remote), parent: nil),
            2: .init(frame: CGRect(x: 300, y: 150, width: 120, height: 90), parent: 1)
        ], rootFrames: [1: root], viewport: CGRect(origin: .zero, size: viewport), pixelsPerPoint: 1, covering: 1)
        let popup = try #require(frames[2])
        #expect(abs(popup.minX - 100) < 0.001)
        #expect(abs(popup.minY - (root.minY + 50)) < 0.001)
        // Ordinary constrained windows keep their established top-fit policy.
        #expect(DesktopGeometry.surfaceFrame(natural: remote, available: viewport, resizing: false).minY == 0)
    }

    @Test func nestedPopupInputUsesItsDisplayedRectAfterParentFitting() throws {
        let frames = DesktopGeometry.popupFrames(windows: [
            1: .init(frame: CGRect(x: 0, y: 0, width: 2400, height: 1600), parent: nil),
            2: .init(frame: CGRect(x: 1200, y: 200, width: 600, height: 400), parent: 1),
            3: .init(frame: CGRect(x: 1500, y: 300, width: 300, height: 200), parent: 2)
        ], rootFrames: [1: CGRect(x: 0, y: 0, width: 600, height: 400)],
           viewport: CGRect(x: 0, y: 0, width: 600, height: 700), pixelsPerPoint: 2, covering: 1)
        let child = try #require(frames[3])
        #expect(child == CGRect(x: 375, y: 75, width: 75, height: 50))
        #expect(DesktopGeometry.remotePoint(CGPoint(x: child.midX, y: child.midY), shown: child,
            remote: CGSize(width: 300, height: 200)) == CGPoint(x: 150, y: 100))
    }
}
