import CoreGraphics
import Testing
@testable import CabooseKit

struct DesktopGeometryTests {
    @Test func localGameReflowsAfterRotationWithoutWaitingForGuestWindow() {
        let guest = CGSize(width: 1280, height: 720)
        for viewport in [CGSize(width: 466, height: 678), CGSize(width: 900, height: 600), CGSize(width: 900, height: 450)] {
            let local = DesktopGeometry.surfaceSize(natural: guest, available: viewport, locallyRendered: true)
            #expect(local == viewport)
            #expect(DesktopGeometry.surfaceFrame(natural: local, available: viewport, resizing: false) == CGRect(origin: .zero, size: viewport))
        }
        #expect(DesktopGeometry.surfaceSize(natural: guest, available: CGSize(width: 466, height: 678), locallyRendered: false) == guest)
    }
    @Test func externalResolutionRespectsScreenAndRenderLimit() {
        #expect(abs(DesktopGeometry.externalPixelsPerPoint(width: 1920, scale: 2, fullResolution: false) - 4.0 / 3.0) < 0.000001)
        #expect(DesktopGeometry.externalPixelsPerPoint(width: 1920, scale: 2, fullResolution: true) == 2)
        #expect(DesktopGeometry.externalPixelsPerPoint(width: 3000, scale: 2, fullResolution: false) == 1)
        #expect(DesktopGeometry.externalPixelsPerPoint(width: 800, scale: 1, fullResolution: false) == 1)
    }
    private let viewport = CGRect(x: 0, y: 0, width: 900, height: 700)

    @Test func popupFollowsFittedParentAndCenteringInset() {
        let frames = DesktopGeometry.popupFrames(windows: [
            1: .init(frame: CGRect(x: 600, y: 0, width: 1200, height: 800), parent: nil),
            2: .init(frame: CGRect(x: 1000, y: 200, width: 400, height: 200), parent: 1)
        ], rootFrames: [1: CGRect(x: 320, y: 10, width: 300, height: 200)],
           viewport: viewport, pixelsPerPoint: 2)
        // 400 guest pixels become 100 points, on top of the root's tile/centering inset.
        #expect(frames[2] == CGRect(x: 420, y: 60, width: 100, height: 50))
    }

    @Test func submenuFollowsClampedParentInsteadOfUnclampedGuestPosition() {
        let frames = DesktopGeometry.popupFrames(windows: [
            1: .init(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), parent: nil),
            2: .init(frame: CGRect(x: 1000, y: 200, width: 400, height: 200), parent: 1),
            3: .init(frame: CGRect(x: 1200, y: 300, width: 120, height: 80), parent: 2)
        ], rootFrames: [1: CGRect(x: 600, y: 0, width: 300, height: 200)],
           viewport: viewport, pixelsPerPoint: 2)
        #expect(frames[2] == CGRect(x: 800, y: 50, width: 100, height: 50))
        #expect(frames[3] == CGRect(x: 850, y: 75, width: 30, height: 20))
    }

    @Test func popupFollowsBothAxesDuringResize() {
        let frames = DesktopGeometry.popupFrames(windows: [
            1: .init(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), parent: nil),
            2: .init(frame: CGRect(x: 400, y: 200, width: 400, height: 200), parent: 1)
        ], rootFrames: [1: CGRect(x: 0, y: 0, width: 300, height: 600)],
           viewport: viewport, pixelsPerPoint: 2)
        #expect(frames[2] == CGRect(x: 100, y: 150, width: 100, height: 150))
    }

    @Test func offscreenOwnerHidesEntireAuxiliaryTree() {
        let windows: [Int: DesktopGeometry.WindowGeometry] = [
            1: .init(frame: CGRect(x: -600, y: 0, width: 600, height: 800), parent: nil),
            2: .init(frame: CGRect(x: -400, y: 100, width: 200, height: 200), parent: 1),
            3: .init(frame: CGRect(x: 0, y: 200, width: 200, height: 100), parent: 2)
        ]
        let hidden = DesktopGeometry.popupFrames(windows: windows,
            rootFrames: [1: CGRect(x: -300, y: 0, width: 300, height: 400)],
            viewport: viewport, pixelsPerPoint: 2)
        #expect(hidden.isEmpty)
        let partial = DesktopGeometry.popupFrames(windows: windows,
            rootFrames: [1: CGRect(x: -100, y: 0, width: 300, height: 400)],
            viewport: viewport, pixelsPerPoint: 2)
        #expect(partial[2] != nil && partial[3] != nil)
    }

    @Test func fullscreenShowsOnlyItsOwnPopupTree() {
        let frames = DesktopGeometry.popupFrames(windows: [
            1: .init(frame: CGRect(x: 0, y: 0, width: 600, height: 800), parent: nil),
            2: .init(frame: CGRect(x: 0, y: 0, width: 600, height: 800), parent: nil),
            3: .init(frame: CGRect(x: 20, y: 20, width: 200, height: 200), parent: 1),
            4: .init(frame: CGRect(x: 20, y: 20, width: 200, height: 200), parent: 2),
            5: .init(frame: CGRect(x: 30, y: 30, width: 100, height: 100), parent: 3),
            6: .init(frame: CGRect(x: 30, y: 30, width: 100, height: 100), parent: nil)
        ], rootFrames: [1: viewport, 2: CGRect(x: 300, y: 0, width: 300, height: 400)],
           viewport: viewport, pixelsPerPoint: 2, covering: 1)
        #expect(Set(frames.keys) == [3, 5])
    }

    @Test func malformedParentTreesDoNotLeaveOrphanMenus() {
        let frames = DesktopGeometry.popupFrames(windows: [
            1: .init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), parent: 2),
            2: .init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), parent: 1),
            3: .init(frame: CGRect(x: 0, y: 0, width: 100, height: 100), parent: 99),
            4: .init(frame: CGRect(x: -200, y: 0, width: 100, height: 100), parent: nil)
        ], rootFrames: [:], viewport: viewport, pixelsPerPoint: 2)
        #expect(frames.isEmpty)
    }

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
        #expect(frame == CGRect(x: 0, y: 0, width: 300, height: 180))
    }

    @Test func minimumSizedWindowFitsWholeAtTop() {
        let frame = DesktopGeometry.surfaceFrame(natural: CGSize(width: 1000, height: 600),
                                                available: CGSize(width: 300, height: 700), resizing: false)
        #expect(frame == CGRect(x: 0, y: 0, width: 300, height: 180))
        let tall = DesktopGeometry.surfaceFrame(natural: CGSize(width: 400, height: 1000),
                                               available: CGSize(width: 300, height: 400), resizing: false)
        #expect(tall == CGRect(x: 70, y: 0, width: 160, height: 400))
    }
    @Test func keyboardTransitionRetainsAspectAndInputAtEverySlotHeight() {
        for fullscreen in [false, true] {
            for remote in [CGSize(width: 1600, height: 1000), CGSize(width: 1600, height: 520)] {
                for height in stride(from: 250, through: 800, by: 5) {
                    let slot = CGSize(width: 800, height: height)
                    let shown = DesktopGeometry.surfaceFrame(natural: remote, available: slot,
                                                             resizing: true, fullscreen: fullscreen)
                    #expect(abs(shown.width / shown.height - remote.width / remote.height) < 0.000001)
                    #expect(shown.maxX <= slot.width && shown.maxY <= slot.height)
                    let mapping = DesktopGeometry.SurfaceMapping(shown: shown, remote: remote)
                    let center = mapping.point(CGPoint(x: shown.midX, y: shown.midY))
                    #expect(abs((center?.x ?? -1) - remote.width / 2) < 0.000001)
                    #expect(abs((center?.y ?? -1) - remote.height / 2) < 0.000001)
                    #expect(shown == DesktopGeometry.surfaceFrame(natural: remote, available: slot,
                                                                  resizing: false, fullscreen: fullscreen))
                }
            }
        }
    }

}
