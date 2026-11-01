import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Laptop's windows through a Steam-like X11 sequence: mapped at a saved size, filled, the
/// app resizing itself back to its old size, and the green button.
struct LaptopFillHoldTests {
    /// The computer, as the compositor treats an X11 window: it takes what the phone
    /// configures, and the app's own size requests unless it is maximized.
    struct Computer {
        var frame: CGRect
        var maximized = false
        mutating func configure(_ layout: LaptopFill.Layout) {
            frame = layout.frame
            maximized = layout.maximized
        }
        /// The app resizes itself (a ConfigureRequest); a maximized window keeps its size.
        mutating func request(_ size: CGSize) {
            if !maximized { frame.size = size }
        }
        /// The app leaves the maximized state itself, then resizes.
        mutating func unmaximizeAndRequest(_ size: CGSize) {
            maximized = false
            frame.size = size
        }
    }

    /// Steam's main window: a 1010 × 600 minimum, no maximum.
    let minimum = CGSize(width: 1010, height: 600)
    /// The size Steam restores when it reloads.
    let saved = CGSize(width: 1100, height: 760)

    /// How the window shows in a viewport: fitted, scaled down, as the desktop draws it.
    func shown(_ frame: CGRect, in viewport: CGSize) -> CGRect {
        DesktopGeometry.surfaceFrame(natural: frame.size, available: viewport, resizing: false)
    }

    func edgeToEdge(_ frame: CGRect, in viewport: CGSize) -> Bool {
        let shown = shown(frame, in: viewport)
        return abs(shown.width - viewport.width) < 1 && abs(shown.height - viewport.height) < 1
    }

    // MARK: A screen the window fits

    /// Laptop's screen below the title bar, larger than Steam's minimum.
    let screen = CGRect(x: 0, y: 64, width: 1338, height: 847)
    /// Where Steam was first placed, its own frame.
    let own = CGRect(x: 0, y: 200, width: 1070, height: 640)

    @Test func appResizingAFilledWindowLeavesStripsWithoutTheHold() {
        // The bug: a filled window the app resizes is drawn fitted into the screen, with
        // the desktop showing beside it.
        var computer = Computer(frame: screen)
        computer.request(CGSize(width: 1010, height: 848))
        #expect(!edgeToEdge(computer.frame, in: screen.size))
        #expect(shown(computer.frame, in: screen.size).minX > 0)
    }

    @Test func aFilledWindowIsMaximizedSoTheAppCannotResizeIt() throws {
        var computer = Computer(frame: CGRect(origin: .zero, size: saved))
        var fill = LaptopFill()
        let filled = try #require(LaptopFill.layout(screen, snap: .maximized, screen: screen, minimum: minimum, maximum: nil))
        #expect(filled == LaptopFill.Layout(frame: screen, maximized: true, held: true))
        #expect(fill.needsConfigure(1, filled, current: computer.frame))
        fill.laidOut(1, filled, current: computer.frame)
        computer.configure(filled)
        // Steam reloads and asks for its saved size: the computer keeps it filled.
        computer.request(saved)
        #expect(computer.frame == screen)
        #expect(fill.restore(1, committed: computer.frame, now: 0) == nil)
        #expect(edgeToEdge(computer.frame, in: screen.size))
        // Nothing changed, so nothing is configured again.
        #expect(!fill.needsConfigure(1, filled, current: computer.frame))
    }

    @Test func anAppThatLeavesMaximizedIsPutBack() throws {
        var computer = Computer(frame: screen)
        var fill = LaptopFill()
        let filled = try #require(LaptopFill.layout(screen, snap: .maximized, screen: screen, minimum: minimum, maximum: nil))
        fill.laidOut(1, filled, current: computer.frame)
        computer.configure(filled)
        computer.unmaximizeAndRequest(saved)
        let restored = fill.restore(1, committed: computer.frame, now: 1)
        let back = try #require(restored)
        computer.configure(back)
        #expect(computer.frame == screen && computer.maximized)
        #expect(fill.restore(1, committed: computer.frame, now: 1.1) == nil)
        #expect(edgeToEdge(computer.frame, in: screen.size))
    }

    @Test func theGreenButtonTogglesBetweenFilledAndItsOwnFrame() throws {
        var computer = Computer(frame: own)
        var fill = LaptopFill()
        func apply(_ snap: FreeDesktopLayout.Snap?) throws {
            let placed = snap == nil ? own : screen
            let layout = try #require(LaptopFill.layout(placed, snap: snap, screen: screen, minimum: minimum, maximum: nil))
            #expect(fill.needsConfigure(1, layout, current: computer.frame))
            fill.laidOut(1, layout, current: computer.frame)
            computer.configure(layout)
        }
        // Filled when Laptop opens; Steam's reload cannot shrink it.
        try apply(.maximized)
        computer.request(saved)
        #expect(computer.frame == screen && computer.maximized)
        // Pressed while filled: back to its own frame, unmaximized and its own again.
        try apply(nil)
        #expect(computer.frame == own && !computer.maximized && !fill.isHeld(1))
        computer.request(CGSize(width: 1100, height: 650))
        #expect(fill.restore(1, committed: computer.frame, now: 2) == nil)
        // Pressed again: filled, then its own frame, each the first time.
        try apply(.maximized)
        #expect(computer.frame == screen && computer.maximized)
        try apply(nil)
        #expect(computer.frame == own && !computer.maximized)
    }

    // MARK: A screen smaller than the window's minimum

    /// A phone's upper screen below the title bar, smaller than Steam's minimum both ways.
    let small = CGRect(x: 0, y: 64, width: 852, height: 516)

    @Test func aWindowHeldLargerThanTheScreenFillsItScaled() throws {
        // Unzoomed or zoomed, it takes the screen's shape grown to its minimum.
        let fitted = CGRect(x: 0, y: 64, width: 1010, height: 612)
        let restored = try #require(LaptopFill.layout(CGRect(x: 0, y: 150, width: 852, height: 400), snap: nil,
                                                      screen: small, minimum: minimum, maximum: nil))
        #expect(restored == LaptopFill.Layout(frame: fitted, maximized: true, held: true))
        let zoomed = try #require(LaptopFill.layout(small, snap: .maximized, screen: small, minimum: minimum, maximum: nil))
        #expect(zoomed == restored)
        // Shown scaled to fit: the screen edge to edge, nothing beside it.
        #expect(edgeToEdge(fitted, in: small.size))
        // At its minimum alone it would leave strips.
        #expect(!edgeToEdge(CGRect(origin: .zero, size: minimum), in: small.size))
    }

    @Test func aFixedSizeWindowLargerThanTheScreenKeepsItsSize() throws {
        let fixed = CGSize(width: 1280, height: 720)
        let layout = try #require(LaptopFill.layout(CGRect(x: 0, y: 64, width: 800, height: 450), snap: nil,
                                                    screen: small, minimum: fixed, maximum: fixed))
        #expect(layout == LaptopFill.Layout(frame: CGRect(x: 0, y: 64, width: 1280, height: 720), maximized: false, held: false))
    }

    @Test func aSmallWindowKeepsItsOwnFrame() throws {
        let frame = CGRect(x: 40, y: 120, width: 600, height: 380)
        let layout = try #require(LaptopFill.layout(frame, snap: nil, screen: small, minimum: CGSize(width: 300, height: 200), maximum: nil))
        #expect(layout == LaptopFill.Layout(frame: frame, maximized: false, held: false))
    }

    // MARK: Holding

    @Test func aHalfIsHeldButNotMaximized() throws {
        let half = CGRect(x: 0, y: 64, width: 669, height: 847)
        let layout = try #require(LaptopFill.layout(half, snap: .left, screen: screen, minimum: CGSize(width: 400, height: 300), maximum: nil))
        #expect(layout == LaptopFill.Layout(frame: half, maximized: false, held: true))
    }

    @Test func aWindowThatCannotTakeItsFrameIsNotChased() throws {
        // A terminal sized in character cells commits a little less than its frame.
        var fill = LaptopFill()
        let layout = LaptopFill.Layout(frame: screen, maximized: true, held: true)
        fill.laidOut(1, layout, current: own)
        let cells = CGRect(x: 0, y: 64, width: 1332, height: 840)
        #expect(fill.restore(1, committed: cells, now: 0) == layout)
        #expect(fill.restore(1, committed: cells, now: 0.1) == nil)
        // Rounding to logical pixels counts as there.
        fill.laidOut(2, layout, current: own)
        #expect(fill.restore(2, committed: CGRect(x: 0, y: 64, width: 1337, height: 846), now: 0) == nil)
    }

    @Test func anAppThatKeepsResizingIsPutBackAFewTimesAPeriod() {
        var fill = LaptopFill()
        let layout = LaptopFill.Layout(frame: screen, maximized: true, held: true)
        fill.laidOut(1, layout, current: screen)
        var restored = 0
        for step in 0..<10 {
            let now = Double(step) * 0.2
            if fill.restore(1, committed: own, now: now) != nil { restored += 1 }
            _ = fill.restore(1, committed: screen, now: now + 0.1)
        }
        #expect(restored == LaptopFill.restores)
        #expect(fill.restore(1, committed: own, now: LaptopFill.period + 1) == layout)
    }

    @Test func releasingForgetsTheHoldAndTheMaximizedState() {
        var fill = LaptopFill()
        let layout = LaptopFill.Layout(frame: screen, maximized: true, held: true)
        fill.laidOut(1, layout, current: own)
        fill.laidOut(2, layout, current: own)
        fill.release(1)
        #expect(!fill.isHeld(1) && !fill.isMaximized(1))
        #expect(fill.restore(1, committed: own, now: 0) == nil)
        // Laptop opening or closing: each window is configured again by its next layout,
        // even one already at its frame, since another layout may have unmaximized it.
        #expect(!fill.needsConfigure(2, layout, current: screen))
        fill.reset()
        #expect(!fill.isHeld(2) && fill.needsConfigure(2, layout, current: screen))
        let own = LaptopFill.Layout(frame: self.own, maximized: false, held: false)
        #expect(fill.needsConfigure(2, own, current: self.own))
        fill.laidOut(2, own, current: self.own)
        #expect(!fill.needsConfigure(2, own, current: self.own))
    }
}
