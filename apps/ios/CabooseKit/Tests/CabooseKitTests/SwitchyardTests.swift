import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Switchyard's track: widths per screen, sharing, stacking, moving, focus, scrolling and drops.
struct SwitchyardTests {
    let third: CGFloat = 1.0 / 3
    let twoThirds: CGFloat = 2.0 / 3

    /// An iPhone 17 Pro Max held upright, beside nothing.
    let phone = YardMetrics(size: CGSize(width: 440, height: 800))
    /// An iPhone Duo opened out and held upright, above its dock.
    let duo = YardMetrics(size: CGSize(width: 669, height: 880))
    /// An iPad Pro 13″ on its side.
    let pad = YardMetrics(size: CGSize(width: 1376, height: 960))
    /// An iPad Pro 13″ held upright.
    let tall = YardMetrics(size: CGSize(width: 1032, height: 1300))

    private func layout(_ windows: [Int], in metrics: YardMetrics) -> YardLayout {
        var layout = YardLayout()
        for window in windows { layout.insert(window, in: metrics) }
        return layout
    }

    // MARK: Metrics

    @Test func presetsFollowTheScreen() {
        // Too narrow for two usable columns: full width only.
        #expect(phone.presets == [1] && duo.presets == [1] && tall.presets == [1])
        #expect(pad.presets == [0.5, twoThirds, 1])
        #expect(phone.columnsInView == 1 && duo.columnsInView == 1 && pad.columnsInView == 2)
        #expect(phone.gap == 3 && pad.gap == 4)
        // A Duo opened out on its side: two columns would each be narrower than a window.
        #expect(YardMetrics(size: CGSize(width: 951, height: 600)).presets == [1])
        // A TV adds thirds.
        #expect(YardMetrics(size: CGSize(width: 1920, height: 1000)).presets == YardMetrics.fractions)
    }

    @Test func outerMarginsAreIndependentOfResizeGaps() {
        for margin in [CGFloat(0), 8] {
            let metrics = YardMetrics(size: CGSize(width: 1000, height: 700), outerGap: margin)
            var layout = YardLayout()
            layout.insert(1, in: metrics)
            let frame = layout.frames(in: metrics)[1]!
            #expect(frame.minX == margin && frame.minY == margin)
            #expect(frame.maxY == metrics.size.height - margin)
            #expect(metrics.points(forFraction: 1) == metrics.size.width - 2 * margin)
            #expect(abs(2 * metrics.points(forFraction: 0.5) + metrics.gap + 2 * margin - metrics.size.width) < 0.001)
        }
    }

    @Test func fractionsTileTheScreenExactly() {
        for metrics in [duo, pad] {
            let half: CGFloat = metrics.points(forFraction: 0.5)
            let filled: CGFloat = 2 * half + metrics.gap + 2 * metrics.outerGap
            #expect(abs(filled - metrics.size.width) < 0.001)
        }
        let thirdWide: CGFloat = pad.points(forFraction: third)
        let filled: CGFloat = 3 * thirdWide + 2 * pad.gap + 2 * pad.outerGap
        #expect(abs(filled - pad.size.width) < 0.001)
        #expect(abs(pad.fraction(forPoints: thirdWide) - third) < 0.0001)
    }

    @Test func aWidthTooNarrowForTheScreenBecomesTheNarrowestThatFits() {
        #expect(phone.effectiveFraction(0.5) == 1)
        #expect(duo.effectiveFraction(third) == 1)
        #expect(pad.effectiveFraction(third) == 0.5)
    }

    // MARK: Sharing the screen

    @Test func newWindowsShareTheScreenWhileTheyFitThenScroll() {
        var layout = layout([1], in: pad)
        #expect(layout.columns.map(\.width) == [1])
        layout.insert(2, in: pad)
        #expect(layout.columns.map(\.windows) == [[1], [2]])
        #expect(layout.columns.allSatisfy { abs($0.width - 0.5) < 0.0001 })
        layout.insert(3, in: pad)
        // One large beside two stacked; then a two by two grid.
        #expect(layout.columns.map(\.windows) == [[1], [2, 3]])
        layout.insert(4, in: pad)
        #expect(layout.columns.map(\.windows) == [[1, 2], [3, 4]])
        #expect(layout.maximumScroll(in: pad) == 0)
        // A fifth would make tiles too small: the track grows past the screen and scrolls.
        layout.insert(5, in: pad)
        #expect(layout.maximumScroll(in: pad) > 0)
        #expect(layout.trackWidth(in: pad) > pad.size.width)
    }

    @Test func onAPhoneEveryColumnIsFullWidth() {
        let layout = layout([1, 2, 3], in: phone)
        let frames = layout.frames(in: phone)
        for id in [1, 2, 3] { #expect(frames[id]?.width == phone.size.width - 2 * phone.outerGap) }
        #expect(frames[2]?.minX == phone.size.width + phone.gap)
        #expect(layout.restingScrolls(in: phone) == [0, 443, 886])
    }

    @Test func closingAWindowGivesItsSpaceBack() {
        var layout = layout([1, 2], in: duo)
        layout.remove(2, in: duo)
        #expect(layout.columns.map(\.width) == [1])
        #expect(layout.focused == 1)
    }

    @Test func aPinnedWidthIsKeptAndTheRestShare() {
        let tv = YardMetrics(size: CGSize(width: 1920, height: 1000))
        var layout = layout([1, 2], in: tv)
        layout.setWidth(twoThirds, column: layout.columns[0].id, in: tv)
        #expect(layout.columns[0].width == twoThirds && layout.columns[0].pinned)
        #expect(abs(layout.columns[1].width - third) < 0.0001)
        layout.insert(3, in: tv)
        // The third window shares the rest of the screen with the second.
        #expect(layout.columns.map(\.windows) == [[1], [2, 3]])
        #expect(abs(layout.columns[1].width - third) < 0.0001)
        #expect(layout.columns[0].width == twoThirds)
    }

    @Test func insertingOpensBesideTheFocusedColumn() {
        var layout = layout([1, 2, 3], in: pad)
        layout.focus(1)
        layout.insert(4, in: pad)
        #expect(layout.windows == [1, 4, 2, 3])
        #expect(layout.focused == 4)
    }

    @Test func aRememberedWidthPinsTheNewColumn() {
        var layout = layout([1], in: pad)
        layout.insert(2, width: twoThirds, in: pad)
        #expect(layout.columns[1].pinned && layout.columns[1].width == twoThirds)
        // The third left beside it is too narrow for the first: it keeps a screen of its own.
        #expect(layout.columns[0].width == 1)
    }

    // MARK: Stacks

    @Test func stackedWindowsSplitTheColumnAndGrowBackWhenOneCloses() {
        var layout = layout([1], in: duo)
        let ok1 = layout.insert(2, below: 1, in: duo)
        #expect(ok1)
        let frames = layout.frames(in: duo)
        let top = frames[1]!, bottom = frames[2]!
        #expect(top.minY == duo.outerGap && bottom.maxY == duo.size.height - duo.outerGap)
        #expect(bottom.minY - top.maxY == duo.gap)
        #expect(abs(top.height - bottom.height) <= 1)
        layout.remove(1, in: duo)
        #expect(layout.columns[0].heights == [1])
        #expect(layout.focused == 2)
    }

    @Test func aStackNeverMakesATileTooShort() {
        var layout = layout([1], in: phone)
        let onPhone = layout.insert(2, below: 1, in: phone)
        #expect(!onPhone && !layout.contains(2))
        var upright = self.layout([1], in: tall)
        let second = upright.insert(2, below: 1, in: tall)
        let third = upright.insert(3, below: 2, in: tall)
        let fourth = upright.insert(4, below: 3, in: tall)
        #expect(second && third && !fourth)
        #expect(upright.columns[0].kept == true)
    }

    @Test func dragsMoveTheSplitAndKeepBothTilesUsable() {
        var layout = layout([1], in: tall)
        layout.insert(2, below: 1, in: tall)
        let id = layout.columns[0].id
        layout.dragSplit(column: id, below: 0, by: 120, in: tall)
        let frames = layout.frames(in: tall)
        #expect(frames[1]!.height > frames[2]!.height)
        layout.dragSplit(column: id, below: 0, by: 5000, in: tall)
        #expect(layout.frames(in: tall)[2]!.height >= YardMetrics.minimumTile.height - 1)
        // Released near a third, it settles on it.
        layout.dragSplit(column: id, below: 0, by: -5000, in: tall)
        layout.dragSplit(column: id, below: 0, by: tall.columnHeight / 3 - YardMetrics.minimumTile.height + 6, in: tall)
        layout.snapSplit(column: id, below: 0, in: tall)
        #expect(abs(layout.columns[0].heights[0] - third) < 0.0001)
        // The split the person chose survives laying the track out again.
        layout.arrange(in: tall)
        #expect(abs(layout.columns[0].heights[0] - third) < 0.0001)
    }

    // MARK: Widths

    @Test func aWidthDragSnapsToTheNearestPreset() {
        var layout = layout([1, 2], in: pad)
        let id = layout.columns[0].id
        layout.drag(column: id, toWidth: pad.points(forFraction: 0.62), in: pad)
        #expect(abs(layout.columns[0].width - 0.62) < 0.0001)
        layout.snapWidth(column: id, in: pad)
        #expect(layout.columns[0].width == twoThirds)
        // A flick carries it on to the next one.
        layout.drag(column: id, toWidth: pad.points(forFraction: 0.52), in: pad)
        layout.snapWidth(column: id, velocity: 1500, in: pad)
        #expect(layout.columns[0].width == twoThirds)
    }

    @Test func widthsCycleThroughThePresets() {
        var layout = layout([1, 2, 3], in: pad)
        let id = layout.columns[0].id
        layout.cycleWidth(column: id, in: pad)
        #expect(layout.columns[0].width == twoThirds)
        layout.cycleWidth(column: id, in: pad)
        #expect(layout.columns[0].width == 1)
        layout.cycleWidth(column: id, in: pad)
        #expect(layout.columns[0].width == 0.5)
    }

    @Test func fullWidthTogglesBackToSharing() {
        var layout = layout([1, 2], in: pad)
        let id = layout.columns[0].id
        layout.toggleFullWidth(column: id, in: pad)
        #expect(layout.columns[0].width == 1 && layout.columns[0].pinned)
        layout.toggleFullWidth(column: id, in: pad)
        #expect(abs(layout.columns[0].width - 0.5) < 0.0001 && !layout.columns[0].pinned)
    }

    @Test func foldingAndUnfoldingRestoresTheLayout() {
        var layout = layout([1, 2], in: duo)
        let frames = layout.frames(in: duo)
        let folded = YardMetrics(size: CGSize(width: 402, height: 780))
        layout.arrange(in: folded)
        #expect(layout.frames(in: folded)[1]!.width == folded.size.width - 2 * folded.outerGap)
        #expect(layout.frames(in: folded)[2]!.minX > folded.size.width)
        layout.arrange(in: duo)
        #expect(layout.frames(in: duo) == frames)
    }

    // MARK: Focus

    @Test func focusMovesAcrossColumnsAtAboutTheSameHeight() {
        var layout = layout([1, 2], in: pad)
        layout.insert(3, below: 2, in: pad)
        layout.focus(1)
        #expect(layout.window(.right) == 2)
        layout.focus(3)
        #expect(layout.window(.left) == 1)
        #expect(layout.window(.up) == 2)
        #expect(layout.window(.down) == nil)
        #expect(layout.window(.right) == nil)
        let movedUp = layout.moveFocus(.up)
        #expect(movedUp && layout.focused == 2)
    }

    // MARK: Moving

    @Test func movingLeftAndRightSwapsColumns() {
        var layout = layout([1, 2], in: pad)
        layout.focus(2)
        let ok4 = layout.moveFocused(.left, in: pad)
        #expect(ok4)
        #expect(layout.columns.map(\.windows) == [[2], [1]])
        let ok5 = layout.moveFocused(.down, in: pad)
        #expect(!ok5)
        let ok6 = layout.moveFocused(.left, in: pad)
        #expect(!ok6)
    }

    @Test func movingOutOfAStackMakesAColumnOnThatSide() {
        var layout = layout([1], in: pad)
        layout.insert(2, below: 1, in: pad)
        let ok7 = layout.moveFocused(.right, in: pad)
        #expect(ok7)
        #expect(layout.columns.map(\.windows) == [[1], [2]])
        #expect(layout.focused == 2)
    }

    @Test func dropsStackSwapAndSplitOffColumns() {
        var layout = layout([1, 2, 3], in: pad)
        let stacked = layout.move(3, to: .stack(column: 0, position: 1), in: pad)
        #expect(stacked)
        #expect(layout.columns.map(\.windows) == [[1, 3], [2]])
        #expect(layout.columns[0].kept == true)
        let swapped = layout.move(2, to: .swap(1), in: pad)
        #expect(swapped)
        #expect(layout.columns.map(\.windows) == [[2, 3], [1]])
        let split = layout.move(3, to: .column(2), in: pad)
        #expect(split)
        #expect(layout.windows == [2, 1, 3])
        #expect(!layout.columns.contains { $0.windows.contains(2) && $0.windows.contains(3) })
        let first = layout.move(3, to: .column(0), in: pad)
        #expect(first)
        #expect(layout.windows == [3, 2, 1])
        for metrics in [pad, duo, phone] {
            var after = layout
            after.arrange(in: metrics)
            let obeys = after.frames(in: metrics).allSatisfy {
                TilePolicy.allows($0.value.size, required: metrics.required($0.key), in: metrics.area)
            }
            #expect(obeys)
        }
    }

    @Test func aFullStackTakesNoMore() {
        var layout = layout([1, 2], in: phone)
        layout.insert(3, below: 1, in: phone)
        let ok13 = layout.move(2, to: .stack(column: 0, position: 0), in: phone)
        #expect(!ok13)
    }

    @Test func dropTargetsFollowThePoint() {
        let layout = layout([1, 2], in: pad)
        let frames = layout.frames(in: pad)
        let middle = frames[2]!
        // Middle of another tile: trade places.
        #expect(layout.drop(for: 1, at: CGPoint(x: middle.midX, y: middle.midY), in: pad) == .swap(2))
        // Its top quarter: stack above it.
        #expect(layout.drop(for: 1, at: CGPoint(x: middle.midX, y: middle.minY + 20), in: pad) == .stack(column: 1, position: 0))
        // Its bottom quarter: stack below it.
        #expect(layout.drop(for: 1, at: CGPoint(x: middle.midX, y: middle.maxY - 20), in: pad) == .stack(column: 1, position: 1))
        // Its right edge: a column of its own after it.
        #expect(layout.drop(for: 1, at: CGPoint(x: middle.maxX - 10, y: middle.midY), in: pad) == .column(2))
        // On a screen too short for a stack, the edges of a tile trade places instead.
        let wide = YardMetrics(size: CGSize(width: 1376, height: 700))
        let short = self.layout([1, 2], in: wide)
        let other = short.frames(in: wide)[2]!
        #expect(short.drop(for: 1, at: CGPoint(x: other.midX, y: other.minY + 20), in: wide) == .swap(2))
        // Beside itself: nothing to do.
        #expect(layout.drop(for: 1, at: CGPoint(x: frames[1]!.midX, y: frames[1]!.midY), in: pad) == nil)
        #expect(layout.drop(for: 1, at: CGPoint(x: middle.minX + 4, y: middle.midY), in: pad) == nil)
    }

    @Test func aPreviewShowsWhereTheTileWouldGo() {
        let layout = layout([1, 2], in: pad)
        let preview = layout.preview(of: .stack(column: 1, position: 1), for: 1, in: pad)
        #expect(preview?.minY ?? 0 > pad.size.height / 3)
        #expect(layout.preview(of: .column(0), for: 1, in: pad) == nil)
    }

    // MARK: Scrolling

    @Test func revealingAColumnScrollsTheLeastNeeded() {
        let layout = layout([1, 2, 3, 4, 5, 6], in: pad)
        #expect(layout.columns.map(\.windows) == [[1, 2], [3, 4], [5], [6]])
        let frames = layout.columnFrames(in: pad)
        let last = frames[layout.columns[3].id]!
        let scroll = layout.scroll(revealing: 6, from: 0, in: pad)
        #expect(scroll == last.maxX + pad.outerGap - pad.size.width)
        #expect(layout.scroll(revealing: 5, from: scroll, in: pad) == scroll)
        #expect(layout.scroll(revealing: 1, from: scroll, in: pad) == 0)
        #expect(layout.visibleColumns(at: scroll, in: pad) == layout.columns.suffix(2).map(\.id))
    }

    @Test func aFlickRestsOnAColumnEdge() {
        let layout = layout([1, 2, 3], in: phone)
        #expect(layout.restingScroll(from: 120, in: phone) == 0)
        #expect(layout.restingScroll(from: 120, velocity: 900, in: phone) == 443)
        #expect(layout.restingScroll(from: 2000, in: phone) == 886)
    }

    @Test func handlesSitInTheGaps() {
        var layout = layout([1, 2], in: pad)
        layout.insert(3, below: 2, in: pad)
        // The stack made by hand stays beside the first window.
        #expect(layout.columns.map(\.windows) == [[1], [2, 3]])
        let handles = layout.handles(in: pad)
        #expect(handles.count == 3)
        let frames = layout.frames(in: pad)
        let split = handles.first { if case .split = $0.kind { true } else { false } }!
        #expect(split.rect.minY == frames[2]!.maxY && split.rect.maxY == frames[3]!.minY)
        let width = handles.first!
        #expect(width.rect.minX == frames[1]!.maxX && width.rect.width == pad.gap)
    }

    // MARK: Memory

    @Test func pruningDropsClosedWindowsAndKeepsFocusOnTheTrack() {
        var layout = layout([1, 2, 3], in: pad)
        layout.prune(keeping: [1, 3], in: pad)
        #expect(layout.windows == [1, 3])
        #expect(layout.focused.map(layout.contains) == true)
    }

    @Test func memoryRoundTripsAndLearnsHandChosenWidths() throws {
        var memory = YardMemory()
        memory.layout = layout([1, 2], in: pad)
        memory.layout.setWidth(twoThirds, column: memory.layout.columns[0].id, in: pad)
        memory.learnWidths { $0 == 1 ? "Chromium" : "foot" }
        #expect(memory.width(for: "chromium") == twoThirds)
        #expect(memory.width(for: "foot") == nil)
        let restored = YardMemory.decoded(from: memory.encoded())
        #expect(restored == memory)
        // New column ids keep counting from where the saved layout left off.
        var layout = restored.layout
        layout.insert(9, in: pad)
        #expect(Set(layout.columns.map(\.id)).count == layout.columns.count)
    }

    @Test func aNewDisplayLifetimeClearsTheTrackButKeepsWidths() {
        var memory = YardMemory()
        // A track kept before epochs were reported is cleared by the first one.
        memory.layout = layout([7], in: pad)
        memory.enter(epoch: nil)
        #expect(memory.layout.windows == [7])
        memory.enter(epoch: "a")
        #expect(memory.layout.isEmpty)
        memory.layout = layout([1, 2], in: pad)
        memory.layout.setWidth(twoThirds, column: memory.layout.columns[0].id, in: pad)
        memory.learnWidths { $0 == 1 ? "Code" : nil }
        memory.enter(epoch: "a")
        memory.enter(epoch: nil)
        #expect(memory.layout.windows.sorted() == [1, 2])
        memory.enter(epoch: "b")
        #expect(memory.layout.isEmpty && memory.width(for: "code") != nil && memory.epoch == "b")
        #expect(YardMemory.decoded(from: memory.encoded()) == memory)
    }

    // MARK: Title bars

    @Test func aTileIsItsTitleBarAndTheWindowBelowIt() {
        let tile = CGRect(x: 10, y: 4, width: 400, height: 300)
        let content = pad.content(ofTile: tile)
        let bar = YardMetrics.titleBar.height
        #expect(content == CGRect(x: 10, y: 4 + bar, width: 400, height: 300 - bar))
        // Reserved once: the bar and the window together are exactly the tile.
        #expect(content.maxY == tile.maxY && content.minY - tile.minY == bar)
        // A tile shorter than its bar leaves the window no height rather than a negative one.
        #expect(pad.content(ofTile: CGRect(x: 0, y: 0, width: 300, height: 20)).height == 0)
        #expect(YardMetrics.titleBar.controls == [.close, .zoom])
    }
}

struct YardSnapTests {
    /// A large monitor, where every palette slot is a usable tile.
    private let metrics = YardMetrics(size: CGSize(width: 2400, height: 1300))

    @Test func everyPaletteRegionProducesAnOrdinaryYardWithoutMutatingTheSource() throws {
        var original = YardLayout()
        for id in 1...6 { original.insert(id, in: metrics) }
        let before = original
        let palette = FreeDesktopLayout.SnapPalette(in: CGRect(origin: .zero, size: metrics.size))
        for region in palette.regions {
            let result = try #require(original.snapping(3, to: region.snap, layout: region.layout, in: metrics))
            #expect(original == before)
            #expect(result.focused == 3)
            #expect(Set(result.windows) == Set(original.windows))
            #expect(result.windows.count == original.windows.count)
            let frame = try #require(result.frames(in: metrics)[3])
            let slot = FreeDesktopLayout.rect(for: region.snap, in: CGRect(x: 0, y: 0, width: 6, height: 6))
            #expect(abs(frame.width - metrics.points(forFraction: slot.width / 6)) < 0.001)
            #expect(abs(frame.height - (slot.height == 6 ? metrics.columnHeight : (metrics.columnHeight - metrics.gap) / 2)) <= 1)
            #expect(palette.selection(at: CGPoint(x: region.frame.midX, y: region.frame.midY)) == region.snap)
            let all = Array(result.frames(in: metrics).values)
            for i in all.indices {
                for j in all.indices where j > i { #expect(!all[i].intersects(all[j])) }
            }
        }
    }

    @Test func quarterSupportsVacanciesOnNarrowWorkspaces() {
        let slots: [FreeDesktopLayout.Snap] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        var yard = YardLayout()
        for id in 1...3 { yard.insert(id, in: metrics) }
        #expect(yard.snapping(1, to: .bottomRight, layout: slots, in: metrics) != nil)
        yard.insert(4, in: metrics)
        #expect(yard.snapping(1, to: .bottomRight, layout: slots, in: metrics) != nil)
        // A phone has no room for halves side by side: the palette does not offer them.
        let phone = YardMetrics(size: CGSize(width: 390, height: 700))
        #expect(yard.snapping(1, to: .left, layout: [.left, .right], in: phone) == nil)
        #expect(yard.snapping(1, to: .maximized, layout: [.maximized], in: phone) != nil)
    }

    @Test func repeatedThirdChoicesRetainTheirOwnCompanionLayout() throws {
        var yard = YardLayout()
        for id in 1...3 { yard.insert(id, in: metrics) }
        let thirds = try #require(yard.snapping(1, to: .leftThird,
            layout: [.leftThird, .centerThird, .rightThird], in: metrics))
        let pair = try #require(yard.snapping(1, to: .leftThird,
            layout: [.leftThird, .rightTwoThirds], in: metrics))
        #expect(thirds.columns.filter { $0.pinned }.count == 3)
        #expect(pair.columns.filter { $0.pinned }.count == 2)
        #expect(pair.columns.contains { abs($0.width - 2.0 / 3) < 0.001 })
    }

    @Test func disabledPaletteRegionsCannotSelectOrFallThrough() {
        let palette = FreeDesktopLayout.SnapPalette(in: CGRect(origin: .zero, size: metrics.size),
            allows: { snap, _ in snap == .maximized })
        for region in palette.regions {
            let point = CGPoint(x: region.frame.midX, y: region.frame.midY)
            #expect(palette.frame.contains(point))
            #expect(palette.selection(at: point) == (region.snap == .maximized ? .maximized : nil))
        }
    }
}


extension YardSnapTests {
    @Test func oneWindowCanReachEveryPaletteSlotWithoutInventingWindows() throws {
        var yard = YardLayout()
        yard.insert(1, in: metrics)
        let palette = FreeDesktopLayout.SnapPalette(in: CGRect(origin: .zero, size: metrics.size))
        for region in palette.regions {
            let result = try #require(yard.snapping(1, to: region.snap, layout: region.layout, in: metrics))
            #expect(result.windows == [1])
            #expect(result.columns.count == 1)
            #expect(abs(result.trackWidth(in: metrics) - metrics.size.width) < 0.001)
            let frame = try #require(result.frames(in: metrics)[1])
            let slot = FreeDesktopLayout.rect(for: region.snap, in: CGRect(x: 0, y: 0, width: 6, height: 6))
            let stride = metrics.size.width + metrics.gap
            #expect(abs(frame.minX - slot.minX / 6 * stride) < 0.001)
            #expect(abs(frame.width - metrics.points(forFraction: slot.width / 6)) < 0.001)
            if slot.height == 3 {
                #expect(abs(frame.height - (metrics.size.height - metrics.gap) / 2) <= 1)
                if slot.minY == 3 { #expect(frame.maxY == metrics.size.height) }
                else { #expect(frame.minY == 0) }
            } else { #expect(frame.height == metrics.size.height) }
            let data = try JSONEncoder().encode(result)
            let restored = try JSONDecoder().decode(YardLayout.self, from: data)
            #expect(restored == result)
            #expect(restored.frames(in: metrics) == result.frames(in: metrics))
        }
    }

    @Test func sparseQuarterAcceptsAStackAndReturnsToTheAutomaticLayoutOnAPhone() throws {
        var yard = YardLayout()
        yard.insert(1, in: metrics)
        var snapped = try #require(yard.snapping(1, to: .bottomRight,
            layout: [.topLeft, .topRight, .bottomLeft, .bottomRight], in: metrics))
        #expect(snapped.trackWidth(in: metrics) == metrics.size.width)
        let inserted = snapped.insert(2, below: 1, in: metrics)
        #expect(inserted)
        #expect(snapped.columns[0].halfSlot == nil)
        let frames = snapped.frames(in: metrics)
        #expect(frames[1]?.minY == 0)
        #expect(frames[2]?.maxY == metrics.size.height)
        #expect(!frames[1]!.intersects(frames[2]!))
        // A quarter of a phone is no usable tile: on one, the windows are laid out afresh.
        let phone = YardMetrics(size: CGSize(width: 390, height: 700))
        snapped.arrange(in: phone)
        let automatic = snapped.columns.allSatisfy { $0.isAutomatic }
        #expect(automatic)
        #expect(snapped.frames(in: phone)[1]?.size == phone.area)
    }
}


extension YardSnapTests {
    @Test func largeMinimumContentFitsEveryVisiblePortraitAndLandscapeSnapRegion() throws {
        // Steam-sized hints are guest pixels, not a native tile's minimum dimensions.
        let minimum = CGSize(width: 1024, height: 640)
        let density: CGFloat = 2
        for size in [CGSize(width: 610, height: 820), CGSize(width: 1024, height: 620),
                     CGSize(width: 390, height: 700)] {
            let metrics = YardMetrics(size: size)
            for count in [1, 4] {
                var yard = YardLayout()
                for id in 1...count { yard.insert(id, in: metrics) }
                let palette = FreeDesktopLayout.SnapPalette(in: CGRect(origin: .zero, size: size),
                    allows: { snap, slots in yard.snapping(1, to: snap, layout: slots, in: metrics) != nil })
                #expect(palette.regions.isEmpty || palette.regions.contains { $0.snap == .maximized && $0.enabled })
                for region in palette.regions where region.enabled {
                    #expect(palette.frame.contains(region.frame))
                    // The view draws two points inside these authoritative hit rectangles.
                    let visible = region.frame.insetBy(dx: 2, dy: 2)
                    for point in [CGPoint(x: visible.minX, y: visible.minY),
                                  CGPoint(x: visible.midX, y: visible.midY),
                                  CGPoint(x: visible.maxX, y: visible.maxY)] {
                        #expect(palette.selection(at: point) == region.snap)
                        #expect(palette.regions.first { $0.frame.contains(point) }?.layout == region.layout)
                    }
                    let result = try #require(yard.snapping(1, to: region.snap, layout: region.layout, in: metrics))
                    #expect(Set(result.windows) == Set(yard.windows))
                    let tile = try #require(result.frames(in: metrics)[1])
                    let unit = FreeDesktopLayout.rect(for: region.snap, in: CGRect(x: 0, y: 0, width: 6, height: 6))
                    #expect(abs(tile.width - metrics.points(forFraction: unit.width / 6)) < 0.001)
                    let viewport = metrics.content(ofTile: tile)
                    let pixels = CGRect(x: viewport.minX * density, y: viewport.minY * density,
                                        width: viewport.width * density, height: viewport.height * density)
                    let committed = try #require(WindowSizePolicy.fitting(pixels, minimum: minimum,
                        maximum: nil, fullscreen: false))
                    #expect(committed.width >= minimum.width && committed.height >= minimum.height)
                    let natural = CGSize(width: committed.width / density, height: committed.height / density)
                    let shown = DesktopGeometry.surfaceFrame(natural: natural, available: viewport.size, resizing: false)
                    // Multiplication by the fitting scale can exceed an edge by a floating-point ULP.
                    #expect(shown.width <= viewport.width + 0.0001 && shown.height <= viewport.height + 0.0001)
                    #expect(abs(shown.width / natural.width - shown.height / natural.height) < 0.0001)
                    // The native surface inverse transform maps both view corners to the
                    // valid committed guest rectangle; hints never enlarge the target tile.
                    #expect(abs(shown.width / (shown.width / natural.width) * density - committed.width) < 0.001)
                    #expect(abs(shown.height / (shown.height / natural.height) * density - committed.height) < 0.001)
                }
            }
        }
    }
}

/// Snap assist and shared dividers in Switchyard: the same model as the floating desktop.
extension YardSnapTests {
    @Test func oneOtherWindowFillsTheOtherHalfAtOnce() throws {
        var yard = YardLayout()
        for id in 1...2 { yard.insert(id, in: metrics) }
        let plan = yard.snapAssist(2, to: .left, layout: [.left, .right], in: metrics)
        #expect(plan.assigned == [.left: 2, .right: 1] && plan.choices.isEmpty)
        let result = try #require(yard.snapping(2, to: .left, layout: [.left, .right], assigned: plan.assigned, in: metrics))
        let frames = result.frames(in: metrics)
        #expect(frames[2]!.minX == 0 && frames[2]!.maxX + metrics.gap == frames[1]!.minX)
        #expect(abs(frames[1]!.maxX - metrics.size.width) < 0.5)
    }

    @Test func moreWindowsAreOfferedForTheOtherHalf() throws {
        var yard = YardLayout()
        for id in 1...3 { yard.insert(id, in: metrics) }
        var plan = yard.snapAssist(1, to: .left, layout: [.left, .right], in: metrics)
        #expect(plan.assigned == [.left: 1] && plan.open == [.right] && plan.choices == [2, 3])
        // Until a choice, the other half stays free.
        let waiting = try #require(yard.snapping(1, to: .left, layout: [.left, .right], assigned: plan.assigned, in: metrics))
        #expect(waiting.frames(in: metrics)[1]!.width == metrics.points(forFraction: 0.5))
        #expect(waiting.columns.first { $0.windows == [1] }?.trailingVacancy == 0.5)
        plan = SnapAssist.choose(3, for: .right, in: plan) { id, slot in yard.slot(slot, accepts: id, in: self.metrics) }
        let chosen = try #require(yard.snapping(1, to: .left, layout: [.left, .right], assigned: plan.assigned, in: metrics))
        let frames = chosen.frames(in: metrics)
        #expect(frames[1]!.maxX + metrics.gap == frames[3]!.minX)
        #expect(Set(chosen.windows) == [1, 2, 3])
    }

    @Test func theEdgeBetweenSnappedWindowsResizesBoth() throws {
        var yard = YardLayout()
        for id in 1...2 { yard.insert(id, in: metrics) }
        var snapped = try #require(yard.snapping(1, to: .left, layout: [.left, .right], in: metrics))
        let left = try #require(snapped.columns.first { $0.windows == [1] })
        snapped.drag(column: left.id, toWidth: 1500, in: metrics)
        var frames = snapped.frames(in: metrics)
        #expect(abs(frames[1]!.width - 1500) < 0.5)
        #expect(frames[1]!.maxX + metrics.gap == frames[2]!.minX && abs(frames[2]!.maxX - metrics.size.width) < 0.5)
        // Not past what the other window needs; letting go keeps it where it is.
        snapped.drag(column: left.id, toWidth: 2390, in: metrics)
        snapped.snapWidth(column: left.id, in: metrics)
        frames = snapped.frames(in: metrics)
        #expect(frames[2]!.width >= TilePolicy.floor.width - 0.5)
        #expect(abs(frames[2]!.maxX - metrics.size.width) < 0.5)
    }

    @Test func closingASnappedWindowLetsTheRestCloseUp() throws {
        var yard = YardLayout()
        for id in 1...2 { yard.insert(id, in: metrics) }
        var snapped = try #require(yard.snapping(1, to: .left, layout: [.left, .right], in: metrics))
        snapped.prune(keeping: [1], in: metrics)
        #expect(snapped.frames(in: metrics)[1]!.size == metrics.area)
    }
}
