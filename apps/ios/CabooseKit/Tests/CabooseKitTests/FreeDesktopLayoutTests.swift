import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// The floating desktop's places: snaps, refitting across desktop sizes, magnetism,
/// switching by direction, and what is kept.
struct FreeDesktopLayoutTests {
    /// An iPad Pro 13″ on its side, above its dock.
    let pad = CGRect(x: 0, y: 0, width: 1376, height: 860)
    /// The same iPad upright.
    let upright = CGRect(x: 0, y: 0, width: 1032, height: 1200)
    /// A TV.
    let tv = CGRect(x: 0, y: 0, width: 1920, height: 980)

    // MARK: Snaps

    @Test func snapsDivideTheWorkArea() {
        #expect(FreeDesktopLayout.rect(for: .maximized, in: pad) == pad)
        #expect(FreeDesktopLayout.rect(for: .left, in: pad) == CGRect(x: 0, y: 0, width: 688, height: 860))
        #expect(FreeDesktopLayout.rect(for: .right, in: pad) == CGRect(x: 688, y: 0, width: 688, height: 860))
        #expect(FreeDesktopLayout.rect(for: .topRight, in: pad) == CGRect(x: 688, y: 0, width: 688, height: 430))
        #expect(FreeDesktopLayout.rect(for: .bottomLeft, in: pad) == CGRect(x: 0, y: 430, width: 688, height: 430))
        // A window that cannot be half as narrow takes its minimum, from the right edge in.
        #expect(FreeDesktopLayout.rect(for: .right, in: pad, minimum: CGSize(width: 800, height: 0))
                == CGRect(x: 576, y: 0, width: 800, height: 860))
        #expect(!FreeDesktopLayout.allows(.left, in: pad, minimum: CGSize(width: 800, height: 100)))
        #expect(FreeDesktopLayout.allows(.maximized, in: pad, minimum: CGSize(width: 1300, height: 800)))
    }

    @Test func zonesFollowTheEdgeTheTitleBarReaches() {
        func zone(_ x: CGFloat, _ y: CGFloat, _ area: CGRect? = nil) -> FreeDesktopLayout.Snap? {
            FreeDesktopLayout.zone(at: CGPoint(x: x, y: y), in: area ?? pad, edge: 12)
        }
        #expect(zone(600, 400) == nil)
        #expect(zone(4, 400) == .left)
        #expect(zone(1370, 400) == .right)
        #expect(zone(600, 6) == .maximized)
        #expect(zone(4, 30) == .topLeft)
        #expect(zone(1372, 850) == .bottomRight)
        // Too small for quarters: the side edge is its half all the way along.
        let duo = CGRect(x: 0, y: 0, width: 760, height: 320)
        #expect(zone(4, 10, duo) == .left)
        #expect(zone(756, 316, duo) == .right)
    }

    // MARK: Refitting

    @Test func refitKeepsEdgesAndCentresAcrossSizes() {
        // Against the right edge, against the right edge.
        let right = CGRect(x: 976, y: 100, width: 400, height: 300)
        #expect(FreeDesktopLayout.refit(right, from: pad, to: upright).maxX == upright.maxX)
        // Centred stays centred.
        let centred = CGRect(x: 488, y: 280, width: 400, height: 300)
        let moved = FreeDesktopLayout.refit(centred, from: pad, to: tv)
        #expect(moved.size == centred.size && moved.midX == tv.midX && moved.midY == tv.midY)
        // Too wide for the new area: as wide as it, never off it.
        let wide = CGRect(x: 100, y: 0, width: 1200, height: 600)
        let narrow = FreeDesktopLayout.refit(wide, from: pad, to: upright)
        #expect(narrow == CGRect(x: 0, y: 0, width: 1032, height: 600))
    }

    @Test func roundTripsDoNotDrift() {
        var layout = FreeDesktopLayout()
        let chosen = CGRect(x: 713, y: 301, width: 1100, height: 520)
        layout.setPreferred(7, frame: chosen, in: tv, app: "Chromium")
        // Every size is derived from what was chosen, so going back gives it back exactly,
        // however many sizes it went through.
        var areas = [pad, upright, CGRect(x: 0, y: 0, width: 700, height: 500), pad, upright]
        areas.append(tv)
        var last = CGRect.zero
        for area in areas {
            last = layout.frame(for: 7, app: "chromium", in: area)!
            #expect(area.contains(last))
        }
        #expect(last == chosen)
    }

    @Test func snappedWindowsFollowTheAreaAndReturnToTheirFrame() {
        var layout = FreeDesktopLayout()
        let chosen = CGRect(x: 200, y: 120, width: 640, height: 480)
        layout.setPreferred(3, frame: chosen, in: pad, app: "Code")
        layout.setSnap(3, .left, current: chosen, in: pad, app: "Code")
        #expect(layout.frame(for: 3, app: "Code", in: tv) == CGRect(x: 0, y: 0, width: 960, height: 980))
        layout.setSnap(3, nil, current: .zero, in: tv, app: "Code")
        #expect(layout.frame(for: 3, app: "Code", in: pad) == chosen)
        // A window snapped before it was ever placed returns to where it was.
        layout.setSnap(4, .maximized, current: chosen, in: pad, app: "Mousepad")
        layout.setSnap(4, nil, current: .zero, in: pad, app: "Mousepad")
        #expect(layout.frame(for: 4, app: "Mousepad", in: pad) == chosen)
    }

    @Test func draggingOutOfASnapRestoresTheSizeUnderTheFinger() {
        let snapped = FreeDesktopLayout.rect(for: .left, in: pad)
        let frame = FreeDesktopLayout.unsnapped(size: CGSize(width: 400, height: 300), from: snapped,
                                                grab: CGPoint(x: 344, y: 12), in: pad)
        // Halfway across the title bar before, halfway across it after.
        #expect(frame == CGRect(x: 144, y: 0, width: 400, height: 300))
        // A frame that would start off the desktop's edge stays on it.
        let wide = FreeDesktopLayout.unsnapped(size: CGSize(width: 1000, height: 600), from: snapped,
                                               grab: CGPoint(x: 600, y: 10), in: pad)
        #expect(wide == CGRect(x: 0, y: 0, width: 1000, height: 600))
    }

    @Test func zoomingAcrossSizesNeverDrifts() {
        var layout = FreeDesktopLayout()
        let chosen = CGRect(x: 301, y: 77, width: 733, height: 511)
        layout.setPreferred(1, frame: chosen, in: pad, app: "Code")
        layout.setSnap(1, .maximized, current: chosen, in: pad, app: "Code")
        // Maximized through every size: it fills each.
        for area in [upright, tv, CGRect(x: 0, y: 0, width: 640, height: 400), pad] {
            #expect(layout.frame(for: 1, app: "Code", in: area) == area)
        }
        // Zoomed back on another screen, and again on the first: the same frame each time.
        layout.setSnap(1, nil, current: tv, in: tv, app: "Code")
        let onTV = layout.frame(for: 1, app: "Code", in: tv)
        for _ in 0..<5 {
            layout.setSnap(1, .maximized, current: onTV!, in: tv, app: "Code")
            layout.setSnap(1, nil, current: tv, in: tv, app: "Code")
        }
        #expect(layout.frame(for: 1, app: "Code", in: tv) == onTV)
        #expect(layout.frame(for: 1, app: "Code", in: pad) == chosen)
    }

    @Test func minimizedWindowsStayMinimizedAndKeepTheirPlace() {
        var layout = FreeDesktopLayout()
        let chosen = CGRect(x: 40, y: 60, width: 500, height: 400)
        layout.setPreferred(6, frame: chosen, in: pad, app: "Thunar")
        layout.setMinimized(6, true)
        #expect(layout.isMinimized(6, app: "Thunar") && !layout.isMinimized(6, app: "Mousepad"))
        // Moving it after it comes back does not lose the state, and the place is the same.
        layout.setSnap(6, .left, current: chosen, in: pad, app: "Thunar")
        #expect(layout.isMinimized(6, app: "Thunar"))
        layout.setSnap(6, nil, current: .zero, in: pad, app: "Thunar")
        #expect(layout.frame(for: 6, app: "Thunar", in: pad) == chosen)
        layout.setMinimized(6, false)
        #expect(!layout.isMinimized(6, app: "Thunar"))
        // A window without a place keeps nothing.
        layout.setMinimized(99, true)
        #expect(layout.places[99] == nil)
        #expect(FreeDesktopLayout.decoded(from: layout.encoded()) == layout)
    }

    // MARK: Magnetism

    @Test func edgesPullOntoTheDesktopAndNeighbours() {
        let neighbour = CGRect(x: 600, y: 100, width: 400, height: 400)
        // Within the threshold of the neighbour's left edge: meets it side to side.
        let near = CGRect(x: 195, y: 150, width: 400, height: 300)
        #expect(FreeDesktopLayout.magnetized(near, others: [neighbour], in: pad, threshold: 10).maxX == 600)
        // Beside it, it also lines up with its top.
        let level = CGRect(x: 195, y: 106, width: 400, height: 300)
        #expect(FreeDesktopLayout.magnetized(level, others: [neighbour], in: pad, threshold: 10)
                == CGRect(x: 200, y: 100, width: 400, height: 300))
        // One far off to the side pulls nothing.
        let apart = CGRect(x: 120, y: 106, width: 300, height: 300)
        #expect(FreeDesktopLayout.magnetized(apart, others: [neighbour], in: pad, threshold: 10) == apart)
        // A window far below is not beside it: no pull from its sides.
        let below = CGRect(x: 600, y: 700, width: 200, height: 100)
        #expect(FreeDesktopLayout.magnetized(near, others: [below], in: pad, threshold: 10) == near)
        // The work area's own edges pull too.
        let corner = CGRect(x: 6, y: 853 - 300, width: 300, height: 300)
        #expect(FreeDesktopLayout.magnetized(corner, others: [], in: pad, threshold: 10).origin == CGPoint(x: 0, y: 560))
    }

    // MARK: Switching

    @Test func neighboursAreFoundByDirection() {
        let frames: [Int: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 400, height: 400),
            2: CGRect(x: 500, y: 0, width: 400, height: 400),
            3: CGRect(x: 520, y: 450, width: 400, height: 400),
            4: CGRect(x: 1000, y: 600, width: 300, height: 200),
        ]
        #expect(FreeDesktopLayout.neighbour(.right, from: frames[1]!, among: frames) == 2)
        #expect(FreeDesktopLayout.neighbour(.down, from: frames[2]!, among: frames) == 3)
        #expect(FreeDesktopLayout.neighbour(.left, from: frames[3]!, among: frames) == 1)
        #expect(FreeDesktopLayout.neighbour(.up, from: frames[1]!, among: frames) == nil)
    }

    // MARK: Keeping

    @Test func placesBelongToTheirApp() {
        var layout = FreeDesktopLayout()
        layout.setPreferred(9, frame: CGRect(x: 10, y: 10, width: 300, height: 200), in: pad, app: "Thunar")
        #expect(layout.frame(for: 9, app: "thunar", in: pad) != nil)
        // After a restart the id belongs to another app: its place is not taken.
        #expect(layout.frame(for: 9, app: "Mousepad", in: pad) == nil)
        // Nor by a window whose class is not known, nor one kept without a class.
        #expect(layout.frame(for: 9, app: nil, in: pad) == nil)
        layout.setPreferred(10, frame: CGRect(x: 10, y: 10, width: 300, height: 200), in: pad, app: nil)
        #expect(layout.frame(for: 10, app: nil, in: pad) == nil && layout.frame(for: 10, app: "Thunar", in: pad) == nil)
        layout.remove(9)
        #expect(layout.places.keys.sorted() == [10])
    }

    @Test func theAnnouncedWindowsAreTheOnlyOnesKept() {
        var layout = FreeDesktopLayout()
        for id in [1, 2, 3] { layout.setPreferred(id, frame: CGRect(x: 0, y: 0, width: 300, height: 200), in: pad, app: "Code") }
        // A cold boot: the computer comes back with only window 2.
        layout.prune(keeping: [2, 8])
        #expect(layout.places.keys.sorted() == [2])
    }

    @Test func theLeastRecentPlacesGoFirst() {
        var layout = FreeDesktopLayout()
        for id in 0..<(FreeDesktopLayout.capacity + 5) {
            layout.setPreferred(id, frame: CGRect(x: 0, y: 0, width: 300, height: 200), in: pad, app: nil)
        }
        #expect(layout.places.count == FreeDesktopLayout.capacity)
        #expect(layout.places[0] == nil && layout.places[4] == nil && layout.places[5] != nil)
    }

    @Test func survivesEncoding() {
        var layout = FreeDesktopLayout()
        layout.setPreferred(2, frame: CGRect(x: 40, y: 50, width: 600, height: 400), in: tv, app: "Chromium")
        layout.setSnap(5, .right, current: CGRect(x: 0, y: 0, width: 500, height: 400), in: tv, app: "Code")
        layout.setMinimized(5, true)
        #expect(FreeDesktopLayout.decoded(from: layout.encoded()) == layout)
        #expect(FreeDesktopLayout.decoded(from: Data("nonsense".utf8)) == FreeDesktopLayout())
    }
}
