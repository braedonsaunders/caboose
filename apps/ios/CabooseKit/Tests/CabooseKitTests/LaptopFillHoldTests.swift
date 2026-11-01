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
        #expect(fill.restore(1, committed: computer.frame) == nil)
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
        let restored = fill.restore(1, committed: computer.frame)
        let back = try #require(restored)
        computer.configure(back)
        #expect(computer.frame == screen && computer.maximized)
        #expect(fill.restore(1, committed: computer.frame) == nil)
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
        #expect(fill.restore(1, committed: computer.frame) == nil)
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
        #expect(fill.restore(1, committed: cells) == layout)
        #expect(fill.restore(1, committed: cells) == nil)
        // Rounding to logical pixels counts as there.
        fill.laidOut(2, layout, current: own)
        #expect(fill.restore(2, committed: CGRect(x: 0, y: 64, width: 1337, height: 846)) == nil)
    }

    /// The phone as Laptop drives a window: configures it to its layout, puts it back when
    /// the hold says so, and lays everything out again (`relayout`) now and then.
    struct Phone {
        var fill = LaptopFill()
        var configures = 0
        mutating func apply(_ layout: LaptopFill.Layout, to computer: inout Computer, always: Bool = false) {
            let needed = always || fill.needsConfigure(1, layout, current: computer.frame)
            fill.laidOut(1, layout, current: computer.frame, configured: needed)
            guard needed else { return }
            configure(layout, &computer)
        }
        mutating func windowChanged(_ computer: inout Computer) {
            guard let layout = fill.restore(1, committed: computer.frame) else { return }
            configure(layout, &computer)
        }
        /// The computer applies the configure, and its window update reaches the phone.
        private mutating func configure(_ layout: LaptopFill.Layout, _ computer: inout Computer) {
            configures += 1
            computer.configure(layout)
            #expect(fill.restore(1, committed: computer.frame) == nil)
        }
    }

    @Test func aFilledWindowIsConfiguredExactlyOnce() throws {
        // Steam reloading every 30 s for five minutes, asking for its saved size each time,
        // while Laptop lays out again now and then: the maximized fill holds it.
        var computer = Computer(frame: CGRect(origin: .zero, size: saved))
        var phone = Phone()
        let filled = try #require(LaptopFill.layout(screen, snap: .maximized, screen: screen, minimum: minimum, maximum: nil))
        phone.apply(filled, to: &computer, always: true)
        for _ in 0..<10 {
            computer.request(saved)
            phone.windowChanged(&computer)
            phone.apply(filled, to: &computer)
        }
        #expect(phone.configures == 1)
        #expect(computer.frame == screen && computer.maximized)
    }

    @Test func aCEFLikeAppThatLeavesItsLayoutIsPutBackOnceThenLeftAlone() throws {
        // CEF answering every configure by leaving the maximized state and restoring its own
        // size, and doing it again every 30 s: Laptop puts it back once, then lets it be,
        // through relayouts, rather than resizing it back and forth.
        var computer = Computer(frame: CGRect(origin: .zero, size: saved))
        var phone = Phone()
        let filled = try #require(LaptopFill.layout(screen, snap: .maximized, screen: screen, minimum: minimum, maximum: nil))
        phone.apply(filled, to: &computer, always: true)
        for _ in 0..<10 {
            computer.unmaximizeAndRequest(saved)
            phone.windowChanged(&computer)
            phone.apply(filled, to: &computer)
        }
        #expect(phone.configures == 2)
        #expect(phone.fill.hasRefused(1) && !phone.fill.isHeld(1))
        #expect(computer.frame.size == saved)
        // The owner pressing the green button lays it out again, once more.
        phone.apply(filled, to: &computer, always: true)
        #expect(phone.configures == 3 && !phone.fill.hasRefused(1))
        // A changed screen is a new layout, tried again.
        let wider = CGRect(x: 0, y: 64, width: 1400, height: 847)
        computer.unmaximizeAndRequest(saved)
        phone.windowChanged(&computer)
        computer.unmaximizeAndRequest(CGSize(width: 1000, height: 700))
        phone.windowChanged(&computer)
        let configures = phone.configures
        phone.apply(try #require(LaptopFill.layout(wider, snap: .maximized, screen: wider, minimum: minimum, maximum: nil)), to: &computer)
        #expect(phone.configures == configures + 1)
    }

    @Test func releasingForgetsTheHoldAndTheMaximizedState() {
        var fill = LaptopFill()
        let layout = LaptopFill.Layout(frame: screen, maximized: true, held: true)
        fill.laidOut(1, layout, current: own)
        fill.laidOut(2, layout, current: own)
        fill.release(1)
        #expect(!fill.isHeld(1) && !fill.isMaximized(1))
        #expect(fill.restore(1, committed: own) == nil)
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
