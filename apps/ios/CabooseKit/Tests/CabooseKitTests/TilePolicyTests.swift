import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// The tile policy against every screen Caboose tiles on and every mix of windows: no tile is
/// ever smaller than a usable window or a bad shape, splits follow the screen, extras go to
/// further screens rather than being squeezed, and the layout survives turning, folding and
/// windows opening and closing.
struct TilePolicyTests {
    /// Screens, in points, held upright. Each is also tried on its side.
    static let screens: [(name: String, size: CGSize)] = [
        ("iPhone SE", CGSize(width: 375, height: 667)),
        ("iPhone 13 mini", CGSize(width: 375, height: 812)),
        ("iPhone 16e", CGSize(width: 390, height: 844)),
        ("iPhone 17", CGSize(width: 402, height: 874)),
        ("iPhone Air", CGSize(width: 420, height: 912)),
        ("iPhone 16 Plus", CGSize(width: 430, height: 932)),
        ("iPhone 17 Pro Max", CGSize(width: 440, height: 956)),
        ("iPhone Duo outer", CGSize(width: 402, height: 874)),
        ("iPhone Duo inner", CGSize(width: 669, height: 951)),
        ("iPad mini", CGSize(width: 744, height: 1133)),
        ("iPad", CGSize(width: 820, height: 1180)),
        ("iPad Pro 11", CGSize(width: 834, height: 1210)),
        ("iPad Pro 13", CGSize(width: 1032, height: 1376)),
        ("TV, 1080p or 4K at 2x", CGSize(width: 1080, height: 1920)),
        ("4K TV at 1x", CGSize(width: 2160, height: 3840)),
    ]

    /// Every screen in both orientations, whole and as the workspace left above a dock and
    /// below the status bar.
    static let metrics: [(name: String, metrics: YardMetrics)] = screens.flatMap { screen in
        [screen.size, CGSize(width: screen.size.height, height: screen.size.width)].flatMap { size in
            let orientation = size.width > size.height ? "landscape" : "portrait"
            return [("\(screen.name) \(orientation)", size),
                    ("\(screen.name) \(orientation) workspace", CGSize(width: size.width, height: size.height - 140))]
                .map { ($0.0, YardMetrics(size: $0.1)) }
        }
    }

    /// Minimum content sizes, in points: none, small, ordinary, large, larger than most
    /// screens, tall and wide.
    static let minimums: [CGSize?] = [nil, CGSize(width: 300, height: 200), CGSize(width: 640, height: 480),
                                      CGSize(width: 800, height: 600), CGSize(width: 1400, height: 1000),
                                      CGSize(width: 240, height: 720), CGSize(width: 960, height: 280)]

    /// Window sets of one to six windows: every mix of minimums for up to three windows, and a
    /// spread of mixes for four to six.
    static let windowSets: [[CGSize?]] = {
        var sets: [[CGSize?]] = []
        for count in 1...3 {
            var indices = Array(repeating: 0, count: count)
            while true {
                sets.append(indices.map { minimums[$0] })
                var position = count - 1
                while position >= 0, indices[position] == minimums.count - 1 { indices[position] = 0; position -= 1 }
                if position < 0 { break }
                indices[position] += 1
            }
        }
        for count in 4...6 {
            for seed in 0..<minimums.count * 3 {
                sets.append((0..<count).map { minimums[(seed * 7 + $0 * (seed % 5 + 1)) % minimums.count] })
            }
        }
        return sets
    }()

    private func with(_ metrics: YardMetrics, _ set: [CGSize?]) -> YardMetrics {
        var metrics = metrics
        metrics.minimums = Dictionary(uniqueKeysWithValues: set.enumerated().compactMap { index, size in size.map { (index + 1, $0) } })
        return metrics
    }

    private func opened(_ count: Int, in metrics: YardMetrics) -> YardLayout {
        var layout = YardLayout()
        for window in 1...count { layout.insert(window, in: metrics) }
        return layout
    }

    /// Every rule a laid-out track must obey on this screen.
    private func check(_ layout: YardLayout, _ metrics: YardMetrics, _ context: String) {
        let frames = layout.frames(in: metrics)
        #expect(layout.windows.count == Set(layout.windows).count, "\(context): a window is tiled twice")
        #expect(Set(frames.keys) == Set(layout.windows), "\(context): a window has no tile")
        for (window, frame) in frames {
            let required = metrics.required(window)
            #expect(TilePolicy.allows(frame.size, required: required, in: metrics.area),
                    "\(context): window \(window) tile \(frame.size) needs \(required)")
            #expect(frame.minY >= metrics.outerGap - 0.5 && frame.maxY <= metrics.size.height - metrics.outerGap + 0.5,
                    "\(context): window \(window) leaves the screen")
        }
        let all = Array(frames.values)
        for i in all.indices {
            for j in all.indices where j > i {
                #expect(!all[i].insetBy(dx: 0.5, dy: 0.5).intersects(all[j]), "\(context): tiles overlap")
            }
        }
        // Automatic screens are filled exactly, so the track rests with each screen whole.
        if layout.columns.allSatisfy({ $0.isAutomatic && !$0.pinned }) {
            let stride = metrics.area.width + metrics.gap
            let screens = (layout.trackWidth(in: metrics) - 2 * metrics.outerGap + metrics.gap) / stride
            #expect(abs(screens - screens.rounded()) < 0.01, "\(context): a screen is not filled (\(screens))")
        }
    }

    @Test func noTileOnAnyScreenBreaksTheRules() {
        for (name, base) in Self.metrics {
            for set in Self.windowSets {
                let metrics = with(base, set)
                let layout = opened(set.count, in: metrics)
                check(layout, metrics, "\(name) \(set)")
                var again = layout
                again.arrange(in: metrics)
                #expect(again == layout, "\(name) \(set): laying out again changes the track")
            }
        }
    }

    @Test func aScreenHoldsAsManyWindowsAsFitAndNoMore() {
        for (name, base) in Self.metrics {
            for set in Self.windowSets {
                let metrics = with(base, set)
                let windows = Array(1...set.count)
                let screens = TilePolicy.screenfuls(windows, in: metrics)
                #expect(screens.flatMap { $0.flatMap(\.windows) } == windows, "\(name): windows lost or reordered")
                var start = 0
                for screen in screens {
                    let count = screen.reduce(0) { $0 + $1.windows.count }
                    if start + count < windows.count, count < TilePolicy.maximumColumns * TilePolicy.maximumRows {
                        #expect(TilePolicy.screenful(Array(windows[start...(start + count)]), in: metrics) == nil,
                                "\(name) \(set): a screen could have held another window")
                    }
                    start += count
                }
            }
        }
    }

    @Test func turningAndFoldingAndBackGivesTheSameLayout() {
        let pairs: [(CGSize, CGSize)] = Self.screens.map { ($0.size, CGSize(width: $0.size.height, height: $0.size.width)) }
            + [(CGSize(width: 669, height: 880), CGSize(width: 402, height: 780)),
               (CGSize(width: 1032, height: 1236), CGSize(width: 744, height: 993))]
        for (first, second) in pairs {
            for set in Self.windowSets {
                let there = with(YardMetrics(size: first), set)
                let back = with(YardMetrics(size: second), set)
                var layout = opened(set.count, in: there)
                let before = layout.frames(in: there)
                layout.arrange(in: back)
                check(layout, back, "\(second) after \(first) \(set)")
                layout.arrange(in: there)
                #expect(layout.frames(in: there) == before, "\(first) → \(second) → back \(set) moved windows")
            }
        }
    }

    @Test func closingAWindowLeavesTheOtherScreensAlone() {
        for (name, base) in Self.metrics {
            for set in Self.windowSets where set.count >= 3 {
                let metrics = with(base, set)
                let layout = opened(set.count, in: metrics)
                for closing in layout.windows {
                    var after = layout
                    after.remove(closing, in: metrics)
                    check(after, metrics, "\(name) \(set) without \(closing)")
                    #expect(after.windows == layout.windows.filter { $0 != closing }, "\(name): closing reordered windows")
                    // Windows in other groups keep their tile's size, unless their group merged
                    // with another across the gap the closed window left.
                    let group = layout.columns.first { $0.windows.contains(closing) }?.group
                    func members(_ layout: YardLayout, _ window: Int) -> Set<Int> {
                        let group = layout.columns.first { $0.windows.contains(window) }?.group
                        return Set(layout.columns.filter { $0.group == group }.flatMap(\.windows)).subtracting([closing])
                    }
                    let sizes = layout.frames(in: metrics), sizesAfter = after.frames(in: metrics)
                    for column in layout.columns where column.group != group {
                        for window in column.windows {
                            let merged = members(layout, window) != members(after, window)
                            #expect(merged || sizes[window]?.size == sizesAfter[window]?.size,
                                    "\(name) \(set): closing \(closing) resized \(window)")
                        }
                    }
                }
            }
        }
    }

    @Test func randomScreensNeverProduceABadTile() {
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<3000 {
            let size = CGSize(width: CGFloat(Int.random(in: 280...4000, using: &generator)),
                              height: CGFloat(Int.random(in: 280...2400, using: &generator)))
            let set = (0..<Int.random(in: 1...6, using: &generator)).map { _ in Self.minimums.randomElement(using: &generator)! }
            let metrics = with(YardMetrics(size: size), set)
            check(opened(set.count, in: metrics), metrics, "\(size) \(set)")
        }
    }

    // MARK: The screen's shape

    @Test func aDuoOpenedUprightStacksTwoWindowsInsteadOfTwoNarrowColumns() {
        let duo = YardMetrics(size: CGSize(width: 669, height: 880))
        let frames = opened(2, in: duo).frames(in: duo)
        #expect(frames[1]!.width == duo.area.width && frames[2]!.width == duo.area.width)
        #expect(frames[1]!.maxY < frames[2]!.minY)
        #expect(frames[1]!.height >= TilePolicy.floor.height && frames[2]!.height >= TilePolicy.floor.height)
        // A third goes to the next screen.
        let three = opened(3, in: duo).frames(in: duo)
        #expect(three[3]!.minX >= duo.size.width)
    }

    @Test func anUprightPhoneShowsOneWindowAScreen() {
        let phone = YardMetrics(size: CGSize(width: 402, height: 740))
        let frames = opened(3, in: phone).frames(in: phone)
        for window in 1...3 {
            #expect(frames[window]!.size == phone.area)
            #expect(frames[window]!.minX == CGFloat(window - 1) * (phone.size.width + phone.gap))
        }
    }

    @Test func aWideIPadSitsTwoSideBySide() {
        let pad = YardMetrics(size: CGSize(width: 1194, height: 760))
        let frames = opened(2, in: pad).frames(in: pad)
        #expect(frames[1]!.minY == frames[2]!.minY && frames[1]!.height == pad.columnHeight)
        #expect(frames[1]!.maxX < frames[2]!.minX && frames[2]!.maxX <= pad.size.width + 0.5)
    }

    @Test func aTVMakesAGridOnlyWhenEveryCellIsUsable() {
        let tv = YardMetrics(size: CGSize(width: 1920, height: 1000))
        // Two: side by side. Three: one large beside two stacked. Four: a two by two grid.
        let two = opened(2, in: tv).frames(in: tv)
        #expect(two[1]!.height == tv.columnHeight && two[2]!.minY == two[1]!.minY)
        let three = opened(3, in: tv)
        #expect(three.columns.map(\.windows.count) == [1, 2])
        let four = opened(4, in: tv)
        #expect(four.columns.map(\.windows.count) == [2, 2])
        let six = opened(6, in: tv)
        #expect(six.columns.map(\.windows.count) == [2, 2, 2])
        // A seventh would make cells too small: it goes to the next screen.
        let seven = opened(7, in: tv)
        #expect(seven.frames(in: tv)[7]!.minX >= tv.size.width)
    }

    @Test func aWindowWithALargeMinimumGetsATileThatFitsIt() {
        var tv = YardMetrics(size: CGSize(width: 1920, height: 1000))
        tv.minimums = [2: CGSize(width: 1100, height: 700)]
        let frames = opened(3, in: tv).frames(in: tv)
        #expect(frames[2]!.width >= 1100 && frames[2]!.height >= 700 + YardMetrics.titleBar.height)
        // Larger than the screen: the whole screen, and the window is shown scaled to fit.
        var phone = YardMetrics(size: CGSize(width: 402, height: 740))
        phone.minimums = [1: CGSize(width: 1280, height: 800)]
        #expect(opened(1, in: phone).frames(in: phone)[1]!.size == phone.area)
    }

    // MARK: Stability

    @Test func unfoldingMergesScreensThatNowFitAndFoldingBackSplitsThemAgain() {
        let outer = YardMetrics(size: CGSize(width: 402, height: 780))
        let inner = YardMetrics(size: CGSize(width: 669, height: 880))
        var layout = opened(4, in: outer)
        #expect(layout.columns.count == 4)
        layout.arrange(in: inner)
        #expect(layout.columns.map(\.windows) == [[1, 2], [3, 4]])
        layout.arrange(in: outer)
        #expect(layout.columns.map(\.windows) == [[1], [2], [3], [4]])
        layout.arrange(in: inner)
        #expect(layout.columns.map(\.windows) == [[1, 2], [3, 4]])
    }

    @Test func aNewWindowOpensBesideTheFocusedOne() {
        let pad = YardMetrics(size: CGSize(width: 1376, height: 900))
        var layout = opened(3, in: pad)
        layout.focus(1)
        layout.insert(9, in: pad)
        #expect(layout.windows == [1, 9, 2, 3])
        #expect(layout.focused == 9)
    }

    @Test func aStackMadeByHandThatNoLongerFitsReturnsToTheAutomaticLayout() {
        let pad = YardMetrics(size: CGSize(width: 1032, height: 1236))
        var layout = YardLayout()
        layout.insert(1, in: pad)
        layout.insert(2, width: 1, in: pad)
        let stacked = layout.insert(3, below: 2, in: pad)
        #expect(stacked)
        #expect(layout.columns[1].kept == true)
        let side = YardMetrics(size: CGSize(width: 1376, height: 700))
        layout.arrange(in: side)
        check(layout, side, "a hand-made stack on its side")
        #expect(layout.columns.allSatisfy { $0.kept != true })
    }

    @Test func aWindowMovedOutOfAStackGetsAColumnOfItsOwn() {
        let duo = YardMetrics(size: CGSize(width: 669, height: 880))
        var layout = opened(2, in: duo)
        #expect(layout.columns.map(\.windows) == [[1, 2]])
        layout.focus(2)
        let moved = layout.moveFocused(.right, in: duo)
        #expect(moved)
        #expect(layout.columns.map(\.windows) == [[1], [2]])
        #expect(layout.frames(in: duo)[2]!.minX >= duo.size.width)
        // It stays apart through turning the phone and back.
        layout.arrange(in: YardMetrics(size: CGSize(width: 951, height: 560)))
        layout.arrange(in: duo)
        #expect(layout.columns.map(\.windows) == [[1], [2]])
        // On a screen with room for two columns, it sits beside the others.
        let pad = YardMetrics(size: CGSize(width: 1376, height: 940))
        layout.arrange(in: pad)
        #expect(layout.frames(in: pad)[2]!.maxX <= pad.size.width + 0.5)
    }

    @Test func aPickedWidthIsNeverNarrowerThanTheScreenAllows() {
        let pad = YardMetrics(size: CGSize(width: 1376, height: 900))
        var layout = opened(2, in: pad)
        layout.setWidth(1.0 / 3, column: layout.columns[0].id, in: pad)
        let frame = layout.frames(in: pad)[layout.columns[0].windows[0]]!
        #expect(TilePolicy.allows(frame.size, required: pad.required(1), in: pad.area))
        // The same column, folded onto a narrow screen, is full width.
        let narrow = YardMetrics(size: CGSize(width: 669, height: 880))
        #expect(layout.frames(in: narrow)[layout.columns[0].windows[0]]!.width == narrow.area.width)
    }

    @Test func theSnapPaletteOffersOnlySlotsThatObeyThePolicy() {
        for size in [CGSize(width: 402, height: 740), CGSize(width: 669, height: 880),
                     CGSize(width: 1194, height: 760), CGSize(width: 1920, height: 1000)] {
            let metrics = YardMetrics(size: size)
            let layout = opened(4, in: metrics)
            let palette = FreeDesktopLayout.SnapPalette(in: CGRect(origin: .zero, size: size)) { snap, slots in
                layout.snapping(1, to: snap, layout: slots, in: metrics) != nil
            }
            for region in palette.regions where region.enabled {
                let result = layout.snapping(1, to: region.snap, layout: region.layout, in: metrics)!
                check(result, metrics, "\(size) \(region.snap)")
            }
            // Full screen is always on offer.
            #expect(palette.regions.isEmpty || palette.regions.contains { $0.snap == .maximized && $0.enabled })
        }
    }

    // MARK: Floating windows

    @Test func dialogsFloatAtTheirOwnSizeCentredOverTheirParent() {
        let bounds = CGRect(x: 0, y: 0, width: 1194, height: 760)
        let parent = CGRect(x: 600, y: 0, width: 594, height: 760)
        let dialog = TilePolicy.dialogFrame(natural: CGSize(width: 400, height: 300), parent: parent, in: bounds)
        #expect(dialog.size == CGSize(width: 400, height: 300))
        #expect(abs(dialog.midX - parent.midX) < 0.5 && abs(dialog.midY - parent.midY) < 0.5)
        // Near an edge it slides in to stay on screen, at its own size.
        let edge = TilePolicy.dialogFrame(natural: CGSize(width: 500, height: 300),
                                          parent: CGRect(x: 1000, y: 0, width: 194, height: 200), in: bounds)
        #expect(edge.size == CGSize(width: 500, height: 300) && edge.maxX <= bounds.maxX - 12 && edge.minY >= 12)
        // Larger than the screen: made smaller to fit it.
        let large = TilePolicy.dialogFrame(natural: CGSize(width: 3000, height: 2000), parent: nil, in: bounds)
        #expect(bounds.insetBy(dx: 12, dy: 12) == large)
    }

    @Test func aLoneWindowTakesTheWholeScreenWhateverItsShape() {
        for size in [CGSize(width: 375, height: 667), CGSize(width: 2000, height: 300), CGSize(width: 300, height: 2000)] {
            let metrics = YardMetrics(size: size)
            #expect(opened(1, in: metrics).frames(in: metrics)[1]!.size == metrics.area)
        }
    }
}

/// A fixed sequence of random numbers, so a failure found by a sweep can be run again.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var value = state
        value ^= value >> 33
        value = value &* 0xff51afd7ed558ccd
        return value ^ (value >> 33)
    }
}
