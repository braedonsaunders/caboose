import CoreGraphics
import Testing
@testable import CabooseKit

/// The title bar's controls: small to see, generous to hit, and answering where they are drawn.
struct WindowTitleBarTests {
    @Test func pointerBarsHaveAMacsMetrics() {
        let bar = WindowTitleBar(touch: false)
        #expect(bar.height == 30 && bar.diameter == 12)
        #expect(bar.centre(of: .close) == 18 && bar.centre(of: .minimize) == 38 && bar.centre(of: .zoom) == 58)
        #expect(bar.controlsWidth == 68)
    }

    @Test func touchKeepsTheCirclesSmallAndTheTargetsLarge() {
        let bar = WindowTitleBar(ui: 0.72, touch: true)
        // Never shrunk below a Mac's size under a finger.
        #expect(bar.height == 32 && bar.diameter == 12)
        #expect(bar.hitFrame(of: .close) == CGRect(x: 0, y: 0, width: 34, height: 32))
        #expect(bar.hitFrame(of: .minimize) == CGRect(x: 34, y: 0, width: 28, height: 32))
        #expect(bar.hitFrame(of: .zoom) == CGRect(x: 62, y: 0, width: 28, height: 32))
        // A TV's bar grows with its UI.
        #expect(WindowTitleBar(ui: 1.5, touch: false).height == 45)
    }

    @Test func eachPointBelongsToOneControlOrTheTitle() {
        let bar = WindowTitleBar(touch: true)
        #expect(bar.control(at: CGPoint(x: 1, y: 1)) == .close)
        #expect(bar.control(at: CGPoint(x: 33.9, y: 31)) == .close)
        #expect(bar.control(at: CGPoint(x: 34, y: 16)) == .minimize)
        #expect(bar.control(at: CGPoint(x: 89, y: 16)) == .zoom)
        #expect(bar.control(at: CGPoint(x: 90, y: 16)) == nil)
        #expect(bar.control(at: CGPoint(x: 10, y: 32)) == nil)
        #expect(bar.control(at: CGPoint(x: 10, y: -1)) == nil)
    }

    @Test func aBarWithoutMinimizeClosesTheGap() {
        // A tiled window has no minimized state, so its bar offers close and zoom only.
        let bar = WindowTitleBar(touch: true, controls: [.close, .zoom])
        #expect(bar.hitFrame(of: .minimize) == nil)
        #expect(bar.control(at: CGPoint(x: 40, y: 10)) == .zoom)
        #expect(bar.controlsWidth == 62)
    }
}
