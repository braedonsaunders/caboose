import CoreGraphics
import Foundation

/// Windows snapped together on the floating desktop: one arrangement of halves, quarters or
/// thirds that tiles the work area, as Switchyard's tiles tile the screen.
///
/// The arrangement is columns of cells, each a fraction of its column. Every edge is computed
/// once and shared by the two windows on either side of it, so snapped windows meet exactly:
/// no overlap and no gap. Dragging the divider between two of them resizes both, never below
/// what either needs (`TilePolicy`). A cell may be empty: a slot snap assist is still offering,
/// or one the person left free. A window that is minimized folds its cell away until it
/// returns; a window that closes or is pulled out of the arrangement gives its space to the
/// others. Rects are whole frames (title bar included) in the work area's units.
public struct SnapGroup: Codable, Equatable, Sendable {
    public typealias Snap = FreeDesktopLayout.Snap

    public struct Cell: Codable, Equatable, Sendable {
        /// The window in the slot; nil for a slot left free or still being offered.
        public var window: Int?
        /// The cell's share of its column's height.
        public var height: CGFloat
        /// The window is minimized: the cell folds away until it returns.
        public var hidden: Bool?
        /// The snap the slot was made from, so assist can name it.
        public var snap: Snap?
    }

    public struct Column: Codable, Equatable, Sendable {
        /// The column's share of the work area's width.
        public var width: CGFloat
        public var cells: [Cell]
    }

    /// A cell, by column and position in it.
    public struct Slot: Hashable, Codable, Sendable {
        public var column: Int
        public var cell: Int
        public init(column: Int, cell: Int) { self.column = column; self.cell = cell }
    }

    public private(set) var columns: [Column]

    /// The arrangement `layout` (snaps that tile the work area, as the snap palette offers
    /// them) with windows in some of its slots. Nil when the snaps do not tile the area.
    public init?(layout: [Snap], assigned: [Snap: Int]) {
        let unit = CGRect(x: 0, y: 0, width: 6, height: 6)
        let rects = layout.map { ($0, FreeDesktopLayout.rect(for: $0, in: unit)) }
        guard rects.reduce(0, { $0 + $1.1.width * $1.1.height }) == 36 else { return nil }
        let byColumn = Dictionary(grouping: rects) { $0.1.minX }
        var columns: [Column] = []
        var x: CGFloat = 0
        for left in byColumn.keys.sorted() {
            let cells = byColumn[left]!.sorted { $0.1.minY < $1.1.minY }
            // A column's cells span exactly its width.
            guard left == x, Set(cells.map(\.1.width)).count == 1,
                  cells.reduce(0, { $0 + $1.1.height }) == 6 else { return nil }
            columns.append(Column(width: cells[0].1.width / 6,
                                  cells: cells.map { Cell(window: assigned[$0.0], height: $0.1.height / 6, snap: $0.0) }))
            x += cells[0].1.width
        }
        guard x == 6 else { return nil }
        self.columns = columns
    }

    // MARK: Reading

    /// Every window in the arrangement, minimized ones included.
    public var windows: [Int] { columns.flatMap { $0.cells.compactMap(\.window) } }
    public func contains(_ window: Int) -> Bool { slot(of: window) != nil }

    public func slot(of window: Int) -> Slot? {
        for (c, column) in columns.enumerated() {
            if let index = column.cells.firstIndex(where: { $0.window == window }) { return Slot(column: c, cell: index) }
        }
        return nil
    }

    public func cell(_ slot: Slot) -> Cell? {
        columns.indices.contains(slot.column) && columns[slot.column].cells.indices.contains(slot.cell)
            ? columns[slot.column].cells[slot.cell] : nil
    }

    /// The free slots, in reading order.
    public var openSlots: [Slot] {
        columns.indices.flatMap { c in
            columns[c].cells.indices.compactMap { columns[c].cells[$0].window == nil ? Slot(column: c, cell: $0) : nil }
        }
    }

    // MARK: Geometry

    private func visible(_ cell: Cell) -> Bool { cell.hidden != true }

    /// Every shown cell's rect in `area`, free slots included. Edges are rounded once and
    /// shared, so neighbours meet exactly.
    public func slotFrames(in area: CGRect) -> [Slot: CGRect] {
        let shown = columns.indices.filter { columns[$0].cells.contains(where: visible) }
        let total = shown.reduce(CGFloat(0)) { $0 + columns[$1].width }
        guard total > 0 else { return [:] }
        var frames: [Slot: CGRect] = [:]
        var share: CGFloat = 0
        for (order, c) in shown.enumerated() {
            let minX = area.minX + (area.width * share / total).rounded()
            share += columns[c].width
            let maxX = order == shown.count - 1 ? area.maxX : area.minX + (area.width * share / total).rounded()
            let cells = columns[c].cells.indices.filter { visible(columns[c].cells[$0]) }
            let height = cells.reduce(CGFloat(0)) { $0 + columns[c].cells[$1].height }
            var down: CGFloat = 0
            for (row, index) in cells.enumerated() {
                let minY = area.minY + (area.height * down / height).rounded()
                down += columns[c].cells[index].height
                let maxY = row == cells.count - 1 ? area.maxY : area.minY + (area.height * down / height).rounded()
                frames[Slot(column: c, cell: index)] = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
        }
        return frames
    }

    /// Each shown window's frame in `area`.
    public func frames(in area: CGRect) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for (slot, frame) in slotFrames(in: area) {
            if let window = cell(slot)?.window { frames[window] = frame }
        }
        return frames
    }

    /// Whether every shown window's frame obeys `TilePolicy` in `area`. `required` is what a
    /// window needs (`TilePolicy.required`), and for nil what a free slot keeps.
    public func obeys(in area: CGRect, required: (Int?) -> CGSize) -> Bool {
        slotFrames(in: area).allSatisfy { slot, frame in
            guard let window = cell(slot)?.window else { return true }
            return TilePolicy.allows(frame.size, required: required(window), in: area.size)
        }
    }

    // MARK: Changes

    /// Puts a window in a free slot (snap assist's choice), taking it out of any other.
    public mutating func assign(_ window: Int, to slot: Slot) {
        guard let current = cell(slot), current.window == nil else { return }
        if let old = self.slot(of: window) { columns[old.column].cells[old.cell].window = nil }
        columns[slot.column].cells[slot.cell].window = window
    }

    /// Takes a window out (it closed, or was pulled away): its space goes to the others in
    /// its column, or its column's space to the other columns. Returns false when no window
    /// is left, and the arrangement is over.
    @discardableResult
    public mutating func remove(_ window: Int) -> Bool {
        guard let slot = slot(of: window) else { return !windows.isEmpty }
        columns[slot.column].cells.remove(at: slot.cell)
        if columns[slot.column].cells.isEmpty { columns.remove(at: slot.column) }
        Self.normalize(&columns)
        return !windows.isEmpty
    }

    /// Minimizes a window (its cell folds away and the others fill the space) or brings it
    /// back to its slot.
    public mutating func setHidden(_ window: Int, _ hidden: Bool) {
        guard let slot = slot(of: window) else { return }
        columns[slot.column].cells[slot.cell].hidden = hidden ? true : nil
    }

    /// Leaves the free slots to the others: assist dismissed with nothing chosen keeps them
    /// as free desktop, so this is for when only free slots would remain beside one window.
    public mutating func removeOpenSlots() {
        for c in columns.indices { columns[c].cells.removeAll { $0.window == nil } }
        columns.removeAll { $0.cells.isEmpty }
        Self.normalize(&columns)
    }

    private static func normalize(_ columns: inout [Column]) {
        let total = columns.reduce(CGFloat(0)) { $0 + $1.width }
        for c in columns.indices {
            if total > 0 { columns[c].width /= total }
            let height = columns[c].cells.reduce(CGFloat(0)) { $0 + $1.height }
            for i in columns[c].cells.indices where height > 0 { columns[c].cells[i].height /= height }
        }
    }

    // MARK: Dividers

    /// A shared edge that can be dragged: between two columns (after the column at `column`),
    /// or between two cells of a column (after the cell at `cell`).
    public enum Divider: Hashable, Sendable {
        case columns(after: Int)
        case cells(column: Int, after: Int)
    }

    /// Each divider and the strip of `thickness` along it, centred on the shared edge.
    public func dividers(in area: CGRect, thickness: CGFloat) -> [(divider: Divider, rect: CGRect)] {
        let frames = slotFrames(in: area)
        var result: [(Divider, CGRect)] = []
        let shown = columns.indices.filter { c in frames.keys.contains { $0.column == c } }
        for a in shown.dropLast() {
            guard let left = frames.first(where: { $0.key.column == a })?.value else { continue }
            result.append((.columns(after: a), CGRect(x: left.maxX - thickness / 2, y: area.minY, width: thickness, height: area.height)))
        }
        for c in shown {
            let cells = columns[c].cells.indices.filter { frames[Slot(column: c, cell: $0)] != nil }
            for (top, _) in zip(cells, cells.dropFirst()) {
                let frame = frames[Slot(column: c, cell: top)]!
                result.append((.cells(column: c, after: top),
                               CGRect(x: frame.minX, y: frame.maxY - thickness / 2, width: frame.width, height: thickness)))
            }
        }
        return result
    }

    /// Moves a divider to `position` (an x for columns, a y for cells, in the work area's
    /// coordinates). Both sides change size; neither goes below what its windows need
    /// (`required`, with nil for a free slot). Where both cannot fit, nothing moves.
    public mutating func drag(_ divider: Divider, to position: CGFloat, in area: CGRect, required: (Int?) -> CGSize) {
        let frames = slotFrames(in: area)
        switch divider {
        case .columns(let after):
            let shown = columns.indices.filter { c in frames.keys.contains { $0.column == c } }
            guard let index = shown.firstIndex(of: after), index + 1 < shown.count else { return }
            let a = after, b = shown[index + 1]
            func span(_ c: Int) -> (CGFloat, CGFloat, CGFloat)? {
                let rects = frames.filter { $0.key.column == c }
                guard let first = rects.first?.value else { return nil }
                let need = rects.map { required(cell($0.key)?.window).width }.max() ?? 0
                return (first.minX, first.maxX, need)
            }
            guard let left = span(a), let right = span(b), left.2 + right.2 <= right.1 - left.0 else { return }
            let x = min(max(position, left.0 + left.2), right.1 - right.2)
            let total = columns[a].width + columns[b].width
            columns[a].width = total * (x - left.0) / (right.1 - left.0)
            columns[b].width = total - columns[a].width
        case .cells(let c, let after):
            let shown = columns[c].cells.indices.filter { frames[Slot(column: c, cell: $0)] != nil }
            guard let index = shown.firstIndex(of: after), index + 1 < shown.count,
                  let top = frames[Slot(column: c, cell: after)], let bottom = frames[Slot(column: c, cell: shown[index + 1])] else { return }
            let b = shown[index + 1]
            let needTop = required(columns[c].cells[after].window).height
            let needBottom = required(columns[c].cells[b].window).height
            guard needTop + needBottom <= bottom.maxY - top.minY else { return }
            let y = min(max(position, top.minY + needTop), bottom.maxY - needBottom)
            let total = columns[c].cells[after].height + columns[c].cells[b].height
            columns[c].cells[after].height = total * (y - top.minY) / (bottom.maxY - top.minY)
            columns[c].cells[b].height = total - columns[c].cells[after].height
        }
    }
}

/// Snap assist: what happens to the rest of an arrangement when one window snaps into it.
///
/// The window takes its slot. When the other windows on the desktop can fill the remaining
/// slots without one left over (one other window beside a half, say), they fill them at once,
/// most recently used first, each in the first slot that suits it (`accepts`). With more
/// windows than slots, the others are offered as choices for the remaining slots, one slot
/// at a time; a slot no window suits stays free.
public enum SnapAssist {
    public typealias Snap = FreeDesktopLayout.Snap

    public struct Plan: Equatable, Sendable {
        /// The windows placed so far, by slot.
        public var assigned: [Snap: Int]
        /// The slots still free, in the layout's order.
        public var open: [Snap]
        /// The windows offered for the free slots, most recently used first; empty once
        /// nothing is left to choose.
        public var choices: [Int]

        /// The slot being offered now: the first free one some choice suits.
        public func offering(accepts: (Int, Snap) -> Bool) -> Snap? {
            open.first { slot in choices.contains { accepts($0, slot) } }
        }
    }

    /// `window` snaps to `snap` of `layout`; `others` are the other windows that could join,
    /// most recently used first.
    public static func plan(_ window: Int, snap: Snap, layout: [Snap], others: [Int],
                            accepts: (Int, Snap) -> Bool) -> Plan {
        settle(Plan(assigned: [snap: window], open: layout.filter { $0 != snap },
                    choices: others.filter { $0 != window }), accepts: accepts)
    }

    /// The person chose `window` for `slot`.
    public static func choose(_ window: Int, for slot: Snap, in plan: Plan, accepts: (Int, Snap) -> Bool) -> Plan {
        guard plan.open.contains(slot), plan.choices.contains(window), accepts(window, slot) else { return plan }
        var plan = plan
        plan.assigned[slot] = window
        plan.open.removeAll { $0 == slot }
        plan.choices.removeAll { $0 == window }
        return settle(plan, accepts: accepts)
    }

    private static func settle(_ plan: Plan, accepts: (Int, Snap) -> Bool) -> Plan {
        var plan = plan
        let eligible = plan.choices.filter { id in plan.open.contains { accepts(id, $0) } }
        guard eligible.count <= plan.open.count else {
            plan.choices = eligible
            return plan
        }
        for id in eligible {
            if let slot = plan.open.first(where: { accepts(id, $0) }) {
                plan.assigned[slot] = id
                plan.open.removeAll { $0 == slot }
            }
        }
        plan.choices = []
        return plan
    }
}
