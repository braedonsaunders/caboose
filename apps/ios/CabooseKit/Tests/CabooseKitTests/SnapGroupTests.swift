import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Snapped windows on the floating desktop: one arrangement whose windows meet exactly,
/// share draggable dividers, fill the rest by snap assist and close up when one leaves.
struct SnapGroupTests {
    typealias Snap = FreeDesktopLayout.Snap

    static let layouts: [[Snap]] = [[.maximized], [.left, .right], [.topLeft, .topRight, .bottomLeft, .bottomRight],
                                    [.leftThird, .centerThird, .rightThird], [.leftTwoThirds, .rightThird],
                                    [.leftThird, .rightTwoThirds]]
    static let areas = [CGRect(x: 0, y: 30, width: 1366, height: 990), CGRect(x: 0, y: 0, width: 1920, height: 1001),
                        CGRect(x: 7, y: 11, width: 1033, height: 1291), CGRect(x: 0, y: 0, width: 951, height: 413)]

    /// No two windows overlap, no gap is left between them, and together they cover the area.
    private func tiles(_ frames: [CGRect], _ area: CGRect) {
        for i in frames.indices {
            #expect(area.contains(frames[i]))
            for j in frames.indices where j > i { #expect(frames[i].intersection(frames[j]).width * frames[i].intersection(frames[j]).height == 0) }
        }
        let covered = frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        #expect(abs(covered - area.width * area.height) < 0.5)
    }

    @Test func everyPaletteArrangementTilesTheAreaExactly() throws {
        for layout in Self.layouts {
            let assigned = Dictionary(uniqueKeysWithValues: layout.enumerated().map { ($0.element, $0.offset + 1) })
            let group = try #require(SnapGroup(layout: layout, assigned: assigned))
            for area in Self.areas {
                let frames = group.frames(in: area)
                #expect(frames.count == layout.count)
                tiles(Array(frames.values), area)
                // Each window sits where its snap would put it.
                for (snap, id) in assigned {
                    let alone = FreeDesktopLayout.rect(for: snap, in: area)
                    #expect(abs(frames[id]!.minX - alone.minX) <= 1 && abs(frames[id]!.width - alone.width) <= 1)
                }
            }
        }
    }

    @Test func snapsThatDoNotTileTheAreaMakeNoArrangement() {
        #expect(SnapGroup(layout: [.left], assigned: [:]) == nil)
        #expect(SnapGroup(layout: [.left, .rightThird], assigned: [:]) == nil)
        #expect(SnapGroup(layout: [.left, .left], assigned: [:]) == nil)
    }

    @Test func aDividerResizesBothSidesWithinWhatTheyNeed() throws {
        let area = CGRect(x: 0, y: 0, width: 1400, height: 900)
        var group = try #require(SnapGroup(layout: [.left, .right], assigned: [.left: 1, .right: 2]))
        let need: (Int?) -> CGSize = { $0 == 2 ? CGSize(width: 500, height: 300) : CGSize(width: 300, height: 300) }
        let divider = try #require(group.dividers(in: area, thickness: 10).first)
        #expect(divider.rect.midX == 700)
        group.drag(divider.divider, to: 900, in: area, required: need)
        var frames = group.frames(in: area)
        #expect(frames[1]!.maxX == 900 && frames[2]!.minX == 900 && frames[2]!.maxX == 1400)
        // Not past what the right window needs, nor the left.
        group.drag(divider.divider, to: 1300, in: area, required: need)
        frames = group.frames(in: area)
        #expect(frames[2]!.width == 500)
        group.drag(divider.divider, to: 10, in: area, required: need)
        frames = group.frames(in: area)
        #expect(frames[1]!.width == 300)
        tiles(Array(frames.values), area)
    }

    @Test func quartersShareAColumnDividerAndHaveTheirOwnRowDividers() throws {
        let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        var group = try #require(SnapGroup(layout: [.topLeft, .topRight, .bottomLeft, .bottomRight],
                                           assigned: [.topLeft: 1, .topRight: 2, .bottomLeft: 3, .bottomRight: 4]))
        let dividers = group.dividers(in: area, thickness: 8)
        #expect(dividers.count == 3)
        let row = try #require(dividers.first { if case .cells(column: 1, after: 0) = $0.divider { true } else { false } })
        group.drag(row.divider, to: 300, in: area, required: { _ in CGSize(width: 200, height: 200) })
        let frames = group.frames(in: area)
        #expect(frames[2]!.maxY == 300 && frames[4]!.minY == 300)
        // The left column's rows did not move.
        #expect(frames[1]!.maxY == 500)
        tiles(Array(frames.values), area)
    }

    @Test func closingOrMinimizingAWindowLetsTheOthersCloseUp() throws {
        let area = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        var group = try #require(SnapGroup(layout: [.leftThird, .centerThird, .rightThird],
                                           assigned: [.leftThird: 1, .centerThird: 2, .rightThird: 3]))
        group.setHidden(2, true)
        var frames = group.frames(in: area)
        #expect(frames[2] == nil)
        tiles(Array(frames.values), area)
        group.setHidden(2, false)
        frames = group.frames(in: area)
        #expect(frames[2]!.minX == 500 && frames[2]!.width == 500)
        let afterThird = group.remove(3)
        #expect(afterThird)
        frames = group.frames(in: area)
        #expect(frames[1]!.width == 750 && frames[2]!.maxX == 1500)
        let afterFirst = group.remove(1)
        #expect(afterFirst)
        #expect(group.frames(in: area)[2] == area)
        let afterLast = group.remove(2)
        #expect(!afterLast)
    }

    @Test func aFreeSlotStaysFreeAndCanBeFilledLater() throws {
        let area = CGRect(x: 0, y: 0, width: 1200, height: 800)
        var group = try #require(SnapGroup(layout: [.left, .right], assigned: [.left: 1]))
        #expect(group.frames(in: area)[1]!.width == 600)
        #expect(group.openSlots.count == 1)
        group.assign(2, to: group.openSlots[0])
        #expect(group.frames(in: area)[2] == CGRect(x: 600, y: 0, width: 600, height: 800))
        #expect(group.openSlots.isEmpty)
    }

    @Test func aGroupObeysTheTilePolicyOnlyWhereEveryWindowFits() throws {
        let group = try #require(SnapGroup(layout: [.left, .right], assigned: [.left: 1, .right: 2]))
        let need: (Int?) -> CGSize = { _ in TilePolicy.floor }
        #expect(group.obeys(in: CGRect(x: 0, y: 0, width: 1366, height: 900), required: need))
        #expect(!group.obeys(in: CGRect(x: 0, y: 0, width: 900, height: 900), required: need))
    }

    // MARK: Snap assist

    @Test func oneOtherWindowFillsTheOtherHalfAtOnce() {
        let plan = SnapAssist.plan(1, snap: .left, layout: [.left, .right], others: [2], accepts: { _, _ in true })
        #expect(plan.assigned == [.left: 1, .right: 2])
        #expect(plan.open.isEmpty && plan.choices.isEmpty)
    }

    @Test func moreWindowsThanSlotsAreOfferedAsChoices() {
        let accepts: (Int, Snap) -> Bool = { _, _ in true }
        var plan = SnapAssist.plan(1, snap: .left, layout: [.left, .right], others: [3, 2, 4], accepts: accepts)
        #expect(plan.assigned == [.left: 1] && plan.open == [.right] && plan.choices == [3, 2, 4])
        #expect(plan.offering(accepts: accepts) == .right)
        plan = SnapAssist.choose(2, for: .right, in: plan, accepts: accepts)
        #expect(plan.assigned == [.left: 1, .right: 2] && plan.open.isEmpty && plan.choices.isEmpty)
    }

    @Test func quartersOfferOneSlotAtATimeAndFillTheLastByThemselves() {
        let accepts: (Int, Snap) -> Bool = { _, _ in true }
        let layout: [Snap] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        var plan = SnapAssist.plan(1, snap: .topLeft, layout: layout, others: [2, 3, 4, 5], accepts: accepts)
        #expect(plan.offering(accepts: accepts) == .topRight && plan.choices.count == 4)
        plan = SnapAssist.choose(5, for: .topRight, in: plan, accepts: accepts)
        // Three windows left for two slots: still a choice.
        #expect(plan.offering(accepts: accepts) == .bottomLeft)
        plan = SnapAssist.choose(3, for: .bottomLeft, in: plan, accepts: accepts)
        // Two windows for one slot: still a choice; then nothing is left to offer.
        plan = SnapAssist.choose(4, for: .bottomRight, in: plan, accepts: accepts)
        #expect(plan.assigned == [.topLeft: 1, .topRight: 5, .bottomLeft: 3, .bottomRight: 4])
        #expect(plan.choices.isEmpty && plan.open.isEmpty)
        // Fewer windows than slots: they fill in at once and the rest stays free.
        let few = SnapAssist.plan(1, snap: .topLeft, layout: layout, others: [2], accepts: accepts)
        #expect(few.assigned == [.topLeft: 1, .topRight: 2] && few.open == [.bottomLeft, .bottomRight] && few.choices.isEmpty)
    }

    @Test func aWindowThatCannotTakeASlotIsNeitherPlacedNorOffered() {
        let accepts: (Int, Snap) -> Bool = { id, _ in id != 9 }
        let plan = SnapAssist.plan(1, snap: .left, layout: [.left, .right], others: [9, 2], accepts: accepts)
        #expect(plan.assigned == [.left: 1, .right: 2] && plan.choices.isEmpty)
    }

    // MARK: On the floating desktop

    @Test func theFloatingDesktopKeepsOneArrangementAndClosesItUp() throws {
        let area = CGRect(x: 0, y: 0, width: 1400, height: 900)
        var layout = FreeDesktopLayout()
        let app: (Int) -> String? = { "app\($0)" }
        let group = try #require(SnapGroup(layout: [.left, .right], assigned: [.left: 1, .right: 2]))
        layout.setGroup(group, current: [1: CGRect(x: 100, y: 100, width: 500, height: 400)], in: area, app: app)
        #expect(layout.snap(of: 1) == .left && layout.snap(of: 2) == .right)
        let left = try #require(layout.frame(for: 1, app: "app1", in: area, minimum: CGSize(width: 900, height: 100)))
        let right = try #require(layout.frame(for: 2, app: "app2", in: area))
        // Exact halves, whatever a window's minimum: snaps never overlap.
        #expect(left.maxX == right.minX && left.width == 700)
        layout.setMinimized(2, true)
        #expect(layout.frame(for: 1, app: "app1", in: area) == area)
        layout.setMinimized(2, false)
        #expect(layout.frame(for: 1, app: "app1", in: area)?.width == 700)
        // Pulled away, a window returns to its own frame; the other fills the area.
        layout.setSnap(1, nil, current: left, in: area, app: "app1")
        #expect(layout.frame(for: 1, app: "app1", in: area) == CGRect(x: 100, y: 100, width: 500, height: 400))
        #expect(layout.frame(for: 2, app: "app2", in: area) == area)
        let restored = FreeDesktopLayout.decoded(from: layout.encoded())
        #expect(restored == layout)
        layout.remove(2)
        #expect(layout.group == nil)
    }

    @Test func aNewArrangementReleasesWindowsOfTheOldOne() throws {
        let area = CGRect(x: 0, y: 0, width: 1400, height: 900)
        var layout = FreeDesktopLayout()
        let app: (Int) -> String? = { "app\($0)" }
        layout.setGroup(SnapGroup(layout: [.left, .right], assigned: [.left: 1, .right: 2]), current: [:], in: area, app: app)
        layout.setGroup(SnapGroup(layout: [.leftThird, .rightTwoThirds], assigned: [.leftThird: 1, .rightTwoThirds: 3]),
                        current: [:], in: area, app: app)
        #expect(layout.snap(of: 2) == nil && layout.snap(of: 3) == .rightTwoThirds)
        #expect(Set(layout.group?.windows ?? []) == [1, 3])
        layout.prune(keeping: [3])
        #expect(layout.group?.windows == [3])
    }

    @Test func everyArrangementHasADefaultForEverySnap() {
        for snap in Snap.allCases {
            let arrangement = FreeDesktopLayout.arrangement(for: snap)
            #expect(arrangement.contains(snap))
            #expect(SnapGroup(layout: arrangement, assigned: [snap: 1]) != nil)
        }
    }
}
