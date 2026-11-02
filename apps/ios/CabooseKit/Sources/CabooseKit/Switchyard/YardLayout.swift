import CoreGraphics
import Foundation

/// Switchyard's layout: the computer's windows tiled on one horizontal track of columns.
///
/// Every column is as tall as the screen and holds one window, or a few stacked. The track
/// can be wider than the screen; the screen shows a stretch of it and scrolls along it.
/// Widths are fractions of the screen and heights fractions of the column.
///
/// Windows the person has not arranged by hand are arranged by `TilePolicy`, in groups: a
/// group is the windows that share a screen, in order, laid out as the screen's shape
/// suits. A new window joins the group beside it when they still all fit on one screen and
/// otherwise starts the next. On a smaller screen (a fold, a rotation) a group that no
/// longer fits continues on the next screen of the track, and on a larger one it closes up
/// again and neighbouring groups that now fit together merge, so turning or folding the
/// device and back gives the same layout. Closing a window re-arranges only its own group.
/// A column the person sized, stacked or snapped keeps that arrangement wherever it obeys
/// the policy; one that does not on a new screen returns to the automatic arrangement.
///
/// Everything is in points on the track: x from the track's left edge, y from the top of
/// the screen. Nothing here knows about Linux pixels or views.
public struct YardLayout: Codable, Equatable, Sendable {
    public struct Column: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        /// Window ids, top to bottom.
        public internal(set) var windows: [Int]
        /// Each window's share of the column's height, top to bottom, summing to 1.
        public internal(set) var heights: [CGFloat]
        /// The column's width as a fraction of the screen.
        public internal(set) var width: CGFloat
        /// Set once the person chooses a width; until then the column shares the screen
        /// evenly with the others, as Split View would.
        public internal(set) var pinned: Bool
        /// Empty portions of a snapped arrangement, without synthetic windows/columns.
        /// Optional for compatibility with saved yards predating sparse arrangements.
        public internal(set) var leadingVacancy: CGFloat?
        public internal(set) var trailingVacancy: CGFloat?
        /// A lone window occupying the top (0) or bottom (1) half of its column.
        public internal(set) var halfSlot: Int?
        /// Explicit palette slots keep their viewport fraction. App size hints constrain
        /// the guest content, which is fitted into this viewport by the native surface.
        public internal(set) var snapSized: Bool?
        /// The automatic group the column's windows belong to (`TilePolicy`).
        public internal(set) var group: Int?
        /// Set when the person built the column by hand: a stack they made or a split they
        /// dragged, or a window they moved into a column of its own. It is kept whole, alone
        /// in its column, wherever that obeys `TilePolicy`.
        public internal(set) var kept: Bool?

        init(id: Int, window: Int, width: CGFloat, pinned: Bool, group: Int? = nil) {
            self.id = id
            windows = [window]
            heights = [1]
            self.width = width
            self.pinned = pinned
            self.group = group
        }

        /// Whether `TilePolicy` arranges the column within its group. A width or stack the
        /// person chose is kept as part of that arrangement; only a snapped arrangement, which
        /// keeps its own slots, is outside it.
        public var isAutomatic: Bool { snapSized != true }

        /// Returns the column to the automatic arrangement.
        mutating func release() {
            pinned = false
            snapSized = nil
            kept = nil
            halfSlot = nil
            leadingVacancy = nil
            trailingVacancy = nil
            group = nil
            heights = YardLayout.even(windows.count)
        }
    }

    public private(set) var columns: [Column] = []
    /// The window that takes the keyboard.
    public private(set) var focused: Int?
    private var nextColumnID = 1
    /// Optional so that tracks saved before groups existed still decode.
    private var nextGroupID: Int?

    private mutating func newGroup() -> Int {
        let id = nextGroupID ?? 1
        nextGroupID = id + 1
        return id
    }

    public init() {}

    // MARK: Reading

    public var windows: [Int] { columns.flatMap(\.windows) }
    public var isEmpty: Bool { columns.isEmpty }
    public func contains(_ window: Int) -> Bool { columnIndex(of: window) != nil }

    public func columnIndex(of window: Int) -> Int? { columns.firstIndex { $0.windows.contains(window) } }

    public func column(id: Int) -> Column? { columns.first { $0.id == id } }

    public var focusedColumnIndex: Int? { focused.flatMap(columnIndex(of:)) }

    // MARK: Geometry

    /// The column's width on this screen, in points. A width too narrow for this screen, or
    /// for one of the column's windows, becomes the narrowest that fits, so folding a phone
    /// never leaves a sliver.
    public func width(of column: Column, in metrics: YardMetrics) -> CGFloat {
        // A width `TilePolicy` chose fits its tiles already: a stack may be narrower than a
        // lone window could be.
        if column.snapSized == true || !column.pinned { return metrics.points(forFraction: column.width) }
        return metrics.points(forFraction: pinnedFraction(column, in: metrics))
    }

    /// A picked width on this screen: itself, or the narrowest this screen and the column's
    /// windows allow.
    func pinnedFraction(_ column: Column, in metrics: YardMetrics) -> CGFloat {
        let needed = column.windows.map { metrics.required($0).width }.max() ?? 0
        return min(1, max(metrics.effectiveFraction(column.width), metrics.fraction(forPoints: needed)))
    }

    /// Each column's rect on the track.
    public func columnFrames(in metrics: YardMetrics) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        var x = metrics.outerGap
        for column in columns {
            let width = width(of: column, in: metrics)
            let stride = metrics.size.width - 2 * metrics.outerGap + metrics.gap
            let preservesSlots = (column.snapSized == true || column.width >= metrics.minimumFraction - 0.0001)
            x += preservesSlots ? (column.leadingVacancy ?? 0) * stride : 0
            frames[column.id] = frame(of: column, x: x, width: width, in: metrics)
            x += width + metrics.gap + (preservesSlots ? (column.trailingVacancy ?? 0) * stride : 0)
        }
        return frames
    }

    /// A column's rect with its left edge at `x`: the screen's height, or the top or bottom
    /// half for a lone window snapped there when that half suits it.
    private func frame(of column: Column, x: CGFloat, width: CGFloat, in metrics: YardMetrics) -> CGRect {
        let frame = CGRect(x: x, y: metrics.outerGap, width: width, height: metrics.columnHeight)
        guard let slot = column.halfSlot, (0...1).contains(slot) else { return frame }
        let half = Self.split(frame, heights: [0.5, 0.5], gap: metrics.gap)[slot]
        let fits = column.windows.allSatisfy {
            TilePolicy.allows(half.size, required: metrics.required($0), in: metrics.area)
        }
        return column.snapSized == true || fits ? half : frame
    }

    /// Whether every tile of a column, as it stands, obeys `TilePolicy` on this screen.
    func obeysPolicy(_ column: Column, in metrics: YardMetrics) -> Bool {
        if column.snapSized == true {
            let needed = column.windows.map { metrics.required($0).width }.max() ?? 0
            guard metrics.points(forFraction: column.width) + TilePolicy.slack >= needed else { return false }
        }
        let rect = frame(of: column, x: 0, width: width(of: column, in: metrics), in: metrics)
        return zip(column.windows, Self.split(rect, heights: column.heights, gap: metrics.gap)).allSatisfy {
            TilePolicy.allows($1.size, required: metrics.required($0), in: metrics.area)
        }
    }

    /// The heights `windows` would share stacked in a column `width` points wide, or nil
    /// when stacking them would make a tile break `TilePolicy`.
    func stackHeights(_ windows: [Int], width: CGFloat, in metrics: YardMetrics) -> [CGFloat]? {
        guard let heights = TilePolicy.shares(metrics.columnHeight, gap: metrics.gap,
                                              minimums: windows.map { metrics.required($0).height }) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: metrics.columnHeight)
        let fits = zip(windows, Self.split(rect, heights: heights, gap: metrics.gap)).allSatisfy {
            TilePolicy.allows($1.size, required: metrics.required($0), in: metrics.area)
        }
        return fits ? heights : nil
    }

    /// Whether `window` can join the stack of the column at `index`.
    public func canStack(_ window: Int, into index: Int, in metrics: YardMetrics) -> Bool {
        guard columns.indices.contains(index) else { return false }
        let column = columns[index]
        let windows = column.windows.filter { $0 != window } + [window]
        var widened = column
        widened.windows = windows
        return stackHeights(windows, width: width(of: widened, in: metrics), in: metrics) != nil
    }

    /// Each window's tile on the track.
    public func frames(in metrics: YardMetrics) -> [Int: CGRect] {
        let columnFrames = columnFrames(in: metrics)
        var frames: [Int: CGRect] = [:]
        for column in columns {
            guard let frame = columnFrames[column.id] else { continue }
            for (window, rect) in zip(column.windows, Self.split(frame, heights: column.heights, gap: metrics.gap)) {
                frames[window] = rect
            }
        }
        return frames
    }

    /// The track's whole width, gaps at both ends included.
    public func trackWidth(in metrics: YardMetrics) -> CGFloat {
        let stride = metrics.size.width - 2 * metrics.outerGap + metrics.gap
        let widths = columns.reduce(CGFloat(0)) { sum, column in
            let vacancy = (column.snapSized == true || column.width >= metrics.minimumFraction - 0.0001)
                ? (column.leadingVacancy ?? 0) + (column.trailingVacancy ?? 0) : 0
            return sum + width(of: column, in: metrics) + vacancy * stride
        }
        return 2 * metrics.outerGap + widths + CGFloat(max(0, columns.count - 1)) * metrics.gap
    }

    static func split(_ frame: CGRect, heights: [CGFloat], gap: CGFloat) -> [CGRect] {
        let available = frame.height - gap * CGFloat(max(0, heights.count - 1))
        var y = frame.minY
        var rects: [CGRect] = []
        for (index, share) in heights.enumerated() {
            // The last tile takes what is left, so rounding never opens a seam at the bottom.
            let height = index == heights.count - 1 ? frame.maxY - y : (available * share).rounded()
            rects.append(CGRect(x: frame.minX, y: y, width: frame.width, height: height))
            y += height + gap
        }
        return rects
    }

    // MARK: Adding and removing windows

    /// Adds a window to the right of the focused column (or at the end) and focuses it. It
    /// joins the automatic arrangement beside it, or, with `width` (a remembered width for
    /// the app), takes a column of its own pinned at that width.
    public mutating func insert(_ window: Int, width: CGFloat? = nil, in metrics: YardMetrics) {
        guard !contains(window) else { return }
        let index = focusedColumnIndex.map { $0 + 1 } ?? columns.count
        let group = width == nil ? newGroup() : nil
        let column = Column(id: nextColumnID, window: window, width: width ?? 1, pinned: width != nil, group: group)
        nextColumnID += 1
        columns.insert(column, at: index)
        focused = window
        arrange(in: metrics)
    }

    /// Adds a window under another one, in its column, when every tile of the stack still
    /// obeys `TilePolicy`.
    @discardableResult
    public mutating func insert(_ window: Int, below other: Int, in metrics: YardMetrics) -> Bool {
        guard !contains(window), let index = columnIndex(of: other),
              canStack(window, into: index, in: metrics),
              let position = columns[index].windows.firstIndex(of: other) else { return false }
        columns[index].windows.insert(window, at: position + 1)
        columns[index].heights = Self.even(columns[index].windows.count)
        columns[index].halfSlot = nil
        columns[index].kept = true
        columns[index].heights = stackHeights(columns[index].windows, width: width(of: columns[index], in: metrics),
                                              in: metrics) ?? columns[index].heights
        focused = window
        arrange(in: metrics)
        return true
    }

    /// Takes a window off the track. Focus moves to the window that takes its place in the
    /// stack, else to the column on its left, else to the one on its right.
    public mutating func remove(_ window: Int, in metrics: YardMetrics) {
        guard let index = columnIndex(of: window), let position = columns[index].windows.firstIndex(of: window) else { return }
        var next: Int?
        let rest = columns[index].windows.filter { $0 != window }
        if !rest.isEmpty { next = rest[min(position, rest.count - 1)] }
        else if index > 0 { next = columns[index - 1].windows.first }
        else if index + 1 < columns.count { next = columns[index + 1].windows.first }
        detach(window, column: index, position: position)
        if focused == window { focused = next }
        arrange(in: metrics)
    }

    private mutating func detach(_ window: Int, column index: Int, position: Int) {
        columns[index].windows.remove(at: position)
        let share = columns[index].heights.remove(at: position)
        if columns[index].windows.isEmpty {
            columns.remove(at: index)
        } else {
            // The others grow into the space, keeping their proportions.
            let rest = 1 - share
            columns[index].heights = rest > 0 ? columns[index].heights.map { $0 / rest } : Self.even(columns[index].windows.count)
            // One window left is no longer a stack the person made.
            if columns[index].windows.count == 1 { columns[index].kept = nil }
        }
    }

    /// Takes off the track every window that no longer exists. A snapped arrangement that
    /// loses a whole slot closes up: its other windows return to the automatic layout and
    /// fill the space.
    public mutating func prune(keeping windows: Set<Int>, in metrics: YardMetrics) {
        for window in self.windows where !windows.contains(window) {
            if let index = columnIndex(of: window), columns[index].snapSized == true, columns[index].windows.count == 1 {
                var low = index, high = index
                while low > 0, columns[low - 1].snapSized == true { low -= 1 }
                while high + 1 < columns.count, columns[high + 1].snapSized == true { high += 1 }
                for other in low...high { columns[other].release() }
            }
            remove(window, in: metrics)
        }
        if let focused, !contains(focused) { self.focused = columns.first?.windows.first }
    }

    // MARK: Focus

    public mutating func focus(_ window: Int) {
        guard contains(window) else { return }
        focused = window
    }

    public enum Direction: Sendable { case left, right, up, down }

    /// The window in that direction from the focused one, or nil at the edge.
    public func window(_ direction: Direction, from window: Int? = nil) -> Int? {
        guard let window = window ?? focused, let index = columnIndex(of: window),
              let position = columns[index].windows.firstIndex(of: window) else { return nil }
        switch direction {
        case .up: return position > 0 ? columns[index].windows[position - 1] : nil
        case .down: return position + 1 < columns[index].windows.count ? columns[index].windows[position + 1] : nil
        case .left, .right:
            let target = direction == .left ? index - 1 : index + 1
            guard columns.indices.contains(target) else { return nil }
            // Keep roughly the same height in the next column.
            let stack = columns[target].windows
            let share = columns[index].heights.prefix(position).reduce(0, +) + columns[index].heights[position] / 2
            var top: CGFloat = 0
            for (window, height) in zip(stack, columns[target].heights) {
                if share <= top + height + 0.0001 { return window }
                top += height
            }
            return stack.last
        }
    }

    @discardableResult
    public mutating func moveFocus(_ direction: Direction) -> Bool {
        guard let next = window(direction) else { return false }
        focused = next
        return true
    }

    // MARK: Moving windows

    /// Moves the focused window: left or right swaps its column with the neighbour, or, from
    /// a stack, gives it a column of its own on that side; up or down reorders the stack.
    @discardableResult
    public mutating func moveFocused(_ direction: Direction, in metrics: YardMetrics) -> Bool {
        guard let window = focused, let index = columnIndex(of: window),
              let position = columns[index].windows.firstIndex(of: window) else { return false }
        switch direction {
        case .up, .down:
            let target = direction == .up ? position - 1 : position + 1
            guard columns[index].windows.indices.contains(target) else { return false }
            columns[index].windows.swapAt(position, target)
            columns[index].heights.swapAt(position, target)
            arrange(in: metrics)
            return true
        case .left, .right:
            if columns[index].windows.count > 1 {
                return move(window, to: .column(direction == .left ? index : index + 1), in: metrics)
            }
            let target = direction == .left ? index - 1 : index + 1
            guard columns.indices.contains(target) else { return false }
            columns.swapAt(index, target)
            arrange(in: metrics)
            return true
        }
    }

    /// Where a dragged tile lands.
    public enum Drop: Hashable, Sendable {
        /// A new column of its own, before the column at this index (the count for the end).
        case column(Int)
        /// Into a column's stack, before the window at this position (the count for the bottom).
        case stack(column: Int, position: Int)
        /// Trading places with another window.
        case swap(Int)
    }

    /// Moves a window to a drop target. Returns false when the move changes nothing.
    @discardableResult
    public mutating func move(_ window: Int, to drop: Drop, in metrics: YardMetrics) -> Bool {
        guard let from = columnIndex(of: window), let position = columns[from].windows.firstIndex(of: window) else { return false }
        switch drop {
        case .swap(let other):
            guard other != window, let to = columnIndex(of: other), let otherPosition = columns[to].windows.firstIndex(of: other) else { return false }
            columns[from].windows[position] = other
            columns[to].windows[otherPosition] = window
        case .column(let index):
            let alone = columns[from].windows.count == 1
            // Its own column already, dropped beside itself: nothing moves.
            if alone, index == from || index == from + 1 { return false }
            if alone {
                let column = columns.remove(at: from)
                columns.insert(column, at: index > from ? index - 1 : index)
            } else {
                // Leaving a stack: the stack stays, so the indices do too.
                detach(window, column: from, position: position)
                // Out of a stack into a column of its own, as the person asked.
                var column = Column(id: nextColumnID, window: window, width: 1, pinned: false, group: columns[from].group)
                column.kept = true
                columns.insert(column, at: min(index, columns.count))
                nextColumnID += 1
            }
        case .stack(let columnIndex, let at):
            guard columns.indices.contains(columnIndex) else { return false }
            let targetID = columns[columnIndex].id
            if columnIndex == from {
                // Reordering within its own stack.
                var at = at
                if at > position { at -= 1 }
                guard at != position else { return false }
                let share = columns[from].heights.remove(at: position)
                columns[from].windows.remove(at: position)
                columns[from].windows.insert(window, at: at)
                columns[from].heights.insert(share, at: at)
                break
            }
            guard canStack(window, into: columnIndex, in: metrics) else { return false }
            detach(window, column: from, position: position)
            guard let target = columns.firstIndex(where: { $0.id == targetID }) else { return false }
            columns[target].windows.insert(window, at: min(at, columns[target].windows.count))
            columns[target].halfSlot = nil
            columns[target].kept = true
            columns[target].heights = stackHeights(columns[target].windows, width: width(of: columns[target], in: metrics),
                                                   in: metrics) ?? Self.even(columns[target].windows.count)
        }
        focused = window
        arrange(in: metrics)
        return true
    }

    // MARK: Sizes

    /// Sets a column's width, as a fraction of the screen, and pins it. It is never made
    /// narrower than this screen or its windows allow.
    public mutating func setWidth(_ fraction: CGFloat, column id: Int, in metrics: YardMetrics) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].snapSized = nil
        columns[index].leadingVacancy = nil
        columns[index].trailingVacancy = nil
        columns[index].halfSlot = nil
        let needed = columns[index].windows.map { metrics.required($0).width }.max() ?? 0
        columns[index].width = min(1, max(metrics.minimumFraction, metrics.fraction(forPoints: needed), fraction))
        columns[index].pinned = true
        if columns[index].windows.count > 1 { columns[index].kept = true }
        arrange(in: metrics)
    }

    /// Sets a column's width from a drag, in points, without snapping.
    public mutating func drag(column id: Int, toWidth points: CGFloat, in metrics: YardMetrics) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        if let next = snappedNeighbour(of: index) {
            // The edge two snapped windows share: both change, neither below what it needs.
            let total = columns[index].width + columns[next].width
            func need(_ column: Column) -> CGFloat {
                metrics.fraction(forPoints: column.windows.map { metrics.required($0).width }.max() ?? 0)
            }
            let least = need(columns[index]), most = total - need(columns[next])
            guard least <= most else { return }
            columns[index].width = min(max(metrics.fraction(forPoints: points), least), most)
            columns[next].width = total - columns[index].width
            return
        }
        setWidth(metrics.fraction(forPoints: points), column: id, in: metrics)
    }

    /// The column right of a snapped one that meets it edge to edge in the same
    /// arrangement, so the gap between them is a shared divider.
    func snappedNeighbour(of index: Int) -> Int? {
        let next = index + 1
        guard columns.indices.contains(next), columns[index].snapSized == true, columns[next].snapSized == true,
              (columns[index].trailingVacancy ?? 0) == 0, (columns[next].leadingVacancy ?? 0) == 0 else { return nil }
        return next
    }

    /// Lets go of a width drag: the column settles on the nearest preset. A divider between
    /// snapped windows stays where it was let go.
    public mutating func snapWidth(column id: Int, velocity: CGFloat = 0, in metrics: YardMetrics) {
        guard let column = column(id: id) else { return }
        if let index = columns.firstIndex(where: { $0.id == id }), snappedNeighbour(of: index) != nil { return }
        let points = width(of: column, in: metrics) + velocity * 0.12
        let presets = metrics.presets
        let nearest = presets.min { abs(metrics.points(forFraction: $0) - points) < abs(metrics.points(forFraction: $1) - points) } ?? 1
        setWidth(nearest, column: id, in: metrics)
    }

    /// The next preset width, wrapping round, as ⌘⌥R does.
    public mutating func cycleWidth(column id: Int, in metrics: YardMetrics) {
        guard let column = column(id: id) else { return }
        let presets = metrics.presets
        let current = metrics.effectiveFraction(column.width)
        let next = presets.first { $0 > current + 0.01 } ?? presets.first ?? 1
        setWidth(next, column: id, in: metrics)
    }

    /// Full width, or back to sharing the screen.
    public mutating func toggleFullWidth(column id: Int, in metrics: YardMetrics) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        if columns[index].pinned, metrics.effectiveFraction(columns[index].width) >= 1 {
            columns[index].release()
            arrange(in: metrics)
        } else {
            setWidth(1, column: id, in: metrics)
        }
    }

    /// Moves the split under the window at `position` in a column by `delta` points.
    public mutating func dragSplit(column id: Int, below position: Int, by delta: CGFloat, in metrics: YardMetrics) {
        guard let index = columns.firstIndex(where: { $0.id == id }), position + 1 < columns[index].heights.count else { return }
        let available = metrics.columnHeight - metrics.gap * CGFloat(columns[index].heights.count - 1)
        guard available > 0 else { return }
        let pair = columns[index].heights[position] + columns[index].heights[position + 1]
        // Neither tile goes below what its window needs.
        let windows = columns[index].windows
        let top = min(pair / 2, metrics.required(windows[position]).height / available)
        let bottom = min(pair / 2, metrics.required(windows[position + 1]).height / available)
        let upper = min(max(top, columns[index].heights[position] + delta / available), pair - bottom)
        columns[index].heights[position] = upper
        columns[index].heights[position + 1] = pair - upper
        columns[index].kept = true
    }

    /// Lets go of a split: it settles on halves or thirds of the pair when close to one.
    public mutating func snapSplit(column id: Int, below position: Int, in metrics: YardMetrics) {
        guard let index = columns.firstIndex(where: { $0.id == id }), position + 1 < columns[index].heights.count else { return }
        let pair = columns[index].heights[position] + columns[index].heights[position + 1]
        let ratio = columns[index].heights[position] / pair
        guard let nearest = [1.0 / 3, 0.5, 2.0 / 3].min(by: { abs($0 - ratio) < abs($1 - ratio) }), abs(nearest - ratio) < 0.06 else { return }
        columns[index].heights[position] = pair * nearest
        columns[index].heights[position + 1] = pair * (1 - nearest)
    }

    /// Lays the track out for this screen by `TilePolicy`: a snapped arrangement or a stack
    /// made by hand that cannot obey the policy here returns to the automatic arrangement,
    /// neighbouring groups that now fit one screen together merge, and each group is
    /// arranged over as many screens as it needs. Call it whenever the screen or a window's
    /// minimum changes; every change to the layout calls it. Laying out the same windows on
    /// the same screen again changes nothing.
    public mutating func arrange(in metrics: YardMetrics) {
        guard metrics.size.width > 0, metrics.size.height > 0 else { return }
        for index in columns.indices where !columns[index].isAutomatic && !obeysPolicy(columns[index], in: metrics) {
            columns[index].release()
        }
        var arranged: [Column] = []
        var reserved = Set(columns.filter { !$0.isAutomatic }.map(\.id))
        var index = 0
        while index < columns.count {
            guard columns[index].isAutomatic else { arranged.append(columns[index]); index += 1; continue }
            var run: [Column] = []
            while index < columns.count, columns[index].isAutomatic { run.append(columns[index]); index += 1 }
            arranged += pack(run, reserved: &reserved, in: metrics)
        }
        columns = arranged
    }

    /// The units `TilePolicy` places for a column: a column the person built or sized kept
    /// whole, or each of its windows alone. A stack that cannot fit even alone on this screen
    /// comes apart.
    private func units(of column: Column, in metrics: YardMetrics) -> [TilePolicy.Unit] {
        let width = column.pinned ? pinnedFraction(column, in: metrics) : nil
        if column.kept == true {
            let unit = TilePolicy.Unit(windows: column.windows, width: width,
                                       heights: column.windows.count > 1 ? column.heights : nil, kept: true)
            if TilePolicy.screenful([unit], in: metrics) != nil { return [unit] }
            return column.windows.map(TilePolicy.Unit.window)
        }
        if column.windows.count == 1, let width { return [TilePolicy.Unit(windows: column.windows, width: width)] }
        return column.windows.map(TilePolicy.Unit.window)
    }

    /// A run of automatic columns, laid out again by group.
    private mutating func pack(_ run: [Column], reserved: inout Set<Int>, in metrics: YardMetrics) -> [Column] {
        typealias Group = (id: Int, units: [TilePolicy.Unit], old: [Column])
        // The groups, in order. A group split by a column moved between its windows goes on
        // as a new group after it.
        var groups: [Group] = []
        var seen = Set<Int>()
        for column in run {
            let units = units(of: column, in: metrics)
            if let id = column.group, let last = groups.last, last.id == id {
                groups[groups.count - 1].units += units
                groups[groups.count - 1].old.append(column)
                continue
            }
            var id = column.group ?? newGroup()
            if seen.contains(id) { id = newGroup() }
            seen.insert(id)
            groups.append((id, units, [column]))
        }
        // Neighbours that fit one screen together share it, until no more do: a merged
        // group may then fit with the one before it.
        var merged = groups
        var changed = true
        while changed {
            changed = false
            var next: [Group] = []
            for group in merged {
                if let last = next.last, TilePolicy.screenful(last.units + group.units, in: metrics) != nil {
                    next[next.count - 1].units += group.units
                    next[next.count - 1].old += group.old
                    changed = true
                } else {
                    next.append(group)
                }
            }
            merged = next
        }
        var result: [Column] = []
        for group in merged {
            for screen in TilePolicy.screenfuls(group.units, in: metrics) {
                for planned in screen {
                    // A column keeps the id of the one its first window was in, so it moves
                    // rather than reappears.
                    let source = group.old.first { $0.windows.contains(planned.windows[0]) }
                    let previous = source.flatMap { reserved.contains($0.id) ? nil : $0 }
                        ?? group.old.first { !reserved.contains($0.id) }
                    let id = previous?.id ?? nextColumnID
                    if previous == nil { nextColumnID += 1 }
                    reserved.insert(id)
                    // A picked width is kept as picked, and fitted to each screen as it is shown.
                    let width = planned.pinned ? source?.width ?? planned.width : planned.width
                    var column = Column(id: id, window: planned.windows[0], width: width, pinned: planned.pinned, group: group.id)
                    column.windows = planned.windows
                    column.heights = planned.heights
                    column.kept = planned.kept ? true : nil
                    result.append(column)
                }
            }
        }
        return result
    }

    // MARK: Scrolling

    /// How far the track can scroll.
    public func maximumScroll(in metrics: YardMetrics) -> CGFloat {
        max(0, trackWidth(in: metrics) - metrics.size.width)
    }

    /// The scroll positions the track rests at: each column's left edge at the screen's left,
    /// and each right edge at the screen's right.
    public func restingScrolls(in metrics: YardMetrics) -> [CGFloat] {
        let maximum = maximumScroll(in: metrics)
        var stops: Set<CGFloat> = [0, maximum]
        for frame in columnFrames(in: metrics).values {
            stops.insert(min(maximum, max(0, frame.minX - metrics.outerGap)))
            stops.insert(min(maximum, max(0, frame.maxX + metrics.outerGap - metrics.size.width)))
        }
        return stops.sorted()
    }

    /// Where a scroll released at `scroll` with `velocity` (points per second) comes to rest.
    public func restingScroll(from scroll: CGFloat, velocity: CGFloat = 0, in metrics: YardMetrics) -> CGFloat {
        // Where it would coast to, as a UIScrollView decelerating at its normal rate does.
        let projected = scroll + velocity * 0.998 / (1 - 0.998) / 1000
        return restingScrolls(in: metrics).min { abs($0 - projected) < abs($1 - projected) } ?? 0
    }

    /// The least scroll from `scroll` that shows the whole of a window's column.
    public func scroll(revealing window: Int, from scroll: CGFloat, in metrics: YardMetrics) -> CGFloat {
        guard let index = columnIndex(of: window), let frame = columnFrames(in: metrics)[columns[index].id] else { return scroll }
        let maximum = maximumScroll(in: metrics)
        var scroll = min(maximum, max(0, scroll))
        // Half a point of slack: column edges are sums of fractions and seldom exact.
        if frame.minX - metrics.outerGap < scroll - 0.5 { scroll = frame.minX - metrics.outerGap }
        else if frame.maxX + metrics.outerGap > scroll + metrics.size.width + 0.5 { scroll = frame.maxX + metrics.outerGap - metrics.size.width }
        return min(maximum, max(0, scroll))
    }

    /// The columns any part of which is on screen at `scroll`.
    public func visibleColumns(at scroll: CGFloat, in metrics: YardMetrics) -> [Int] {
        let view = CGRect(x: scroll + 0.5, y: 0, width: max(0, metrics.size.width - 1), height: metrics.size.height)
        let frames = columnFrames(in: metrics)
        return columns.compactMap { column in frames[column.id].flatMap { $0.intersects(view) ? column.id : nil } }
    }

    // MARK: Handles and drops

    /// A gap that can be dragged.
    public struct Handle: Equatable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// The gap right of a column: dragging it sets the column's width.
            case width(column: Int)
            /// The gap under the window at `position` in a column.
            case split(column: Int, position: Int)
        }

        public let kind: Kind
        /// The gap itself, on the track.
        public let rect: CGRect
    }

    public func handles(in metrics: YardMetrics) -> [Handle] {
        let columnFrames = columnFrames(in: metrics)
        var handles: [Handle] = []
        for column in columns {
            guard let frame = columnFrames[column.id] else { continue }
            handles.append(Handle(kind: .width(column: column.id),
                                  rect: CGRect(x: frame.maxX, y: frame.minY, width: metrics.gap, height: frame.height)))
            let tiles = Self.split(frame, heights: column.heights, gap: metrics.gap)
            for (position, tile) in tiles.dropLast().enumerated() {
                handles.append(Handle(kind: .split(column: column.id, position: position),
                                      rect: CGRect(x: tile.minX, y: tile.maxY, width: tile.width, height: metrics.gap)))
            }
        }
        return handles
    }

    /// Where `window`, dragged to `point` on the track, would land. The outer fifth of a
    /// column, or a gap, makes a new column on that side; the top or bottom quarter of a
    /// tile stacks it there; the middle trades places.
    public func drop(for window: Int, at point: CGPoint, in metrics: YardMetrics) -> Drop? {
        guard let from = columnIndex(of: window) else { return nil }
        let columnFrames = columnFrames(in: metrics)
        for (index, column) in columns.enumerated() {
            guard let frame = columnFrames[column.id] else { continue }
            let span = frame.insetBy(dx: -metrics.gap / 2, dy: -metrics.gap)
            guard point.x >= span.minX, point.x < span.maxX else { continue }
            let band = min(frame.width / 5, 96)
            let alone = columns[from].windows.count == 1
            if point.x < frame.minX + band { return index == from && alone || index == from + 1 && alone ? nil : .column(index) }
            if point.x > frame.maxX - band { return index == from && alone || index + 1 == from && alone ? nil : .column(index + 1) }
            let tiles = Self.split(frame, heights: column.heights, gap: metrics.gap)
            for (position, tile) in tiles.enumerated() where point.y < tile.maxY + metrics.gap || position == tiles.count - 1 {
                let target = column.windows[position]
                let room = index == from || canStack(window, into: index, in: metrics)
                let quarter = tile.height / 4
                if room, point.y < tile.minY + quarter, target != window { return stackDrop(index, position, window, from) }
                if room, point.y > tile.maxY - quarter, target != window { return stackDrop(index, position + 1, window, from) }
                return target == window ? nil : .swap(target)
            }
        }
        // Past either end of the track.
        if point.x < (columnFrames[columns.first?.id ?? 0]?.minX ?? 0) { return from == 0 && columns[from].windows.count == 1 ? nil : .column(0) }
        return from == columns.count - 1 && columns[from].windows.count == 1 ? nil : .column(columns.count)
    }

    private func stackDrop(_ column: Int, _ position: Int, _ window: Int, _ from: Int) -> Drop? {
        if column == from, let current = columns[from].windows.firstIndex(of: window), position == current || position == current + 1 { return nil }
        return .stack(column: column, position: position)
    }

    /// The space a drop would give the window, on the track, to preview it.
    public func preview(of drop: Drop, for window: Int, in metrics: YardMetrics) -> CGRect? {
        var after = self
        guard after.move(window, to: drop, in: metrics) else { return nil }
        return after.frames(in: metrics)[window]
    }

    static func even(_ count: Int) -> [CGFloat] { Array(repeating: 1 / CGFloat(max(1, count)), count: count) }
}

extension YardLayout {
    /// The other windows, nearest first along the track from `window` and wrapping round:
    /// the windows snap assist fills an arrangement with, or offers.
    public func nearby(_ window: Int) -> [Int] {
        guard let source = columnIndex(of: window) else { return [] }
        return (Array(columns[source...].flatMap(\.windows)) + columns[..<source].flatMap(\.windows)).filter { $0 != window }
    }

    /// A palette slot's tile size on this screen.
    public func slotSize(_ snap: FreeDesktopLayout.Snap, in metrics: YardMetrics) -> CGSize {
        let unit = FreeDesktopLayout.rect(for: snap, in: CGRect(x: 0, y: 0, width: 6, height: 6))
        let height = unit.height == 6 ? metrics.columnHeight : (metrics.columnHeight - metrics.gap) / 2
        return CGSize(width: metrics.points(forFraction: unit.width / 6), height: height)
    }

    /// Whether `window` can take `snap`'s slot under `TilePolicy`.
    public func slot(_ snap: FreeDesktopLayout.Snap, accepts window: Int, in metrics: YardMetrics) -> Bool {
        TilePolicy.allows(slotSize(snap, in: metrics), required: metrics.required(window), in: metrics.area)
    }

    /// Snap assist for `window` snapping to `snap` of `slots`: the windows that fill the other
    /// slots at once, or the choices offered for them (`SnapAssist`).
    public func snapAssist(_ window: Int, to snap: FreeDesktopLayout.Snap, layout slots: [FreeDesktopLayout.Snap],
                           in metrics: YardMetrics) -> SnapAssist.Plan {
        SnapAssist.plan(window, snap: snap, layout: slots, others: nearby(window)) { id, slot in
            self.slot(slot, accepts: id, in: metrics)
        }
    }

    /// A proposed native palette arrangement, expressed entirely as ordinary Yard columns.
    /// The source stays untouched until release. Unfilled slots reserve space in the
    /// existing column geometry; they do not create windows or a second layout engine.
    ///
    /// `assigned` names the window for each other slot (snap assist's plan, `snapAssist`);
    /// slots it leaves out stay free. Without it, nearby windows fill every slot.
    public func snapping(_ window: Int, to snap: FreeDesktopLayout.Snap,
                         layout slots: [FreeDesktopLayout.Snap], assigned: [FreeDesktopLayout.Snap: Int]? = nil,
                         in metrics: YardMetrics) -> YardLayout? {
        guard let source = columnIndex(of: window), slots.contains(snap),
              Set(slots).count == slots.count else { return nil }
        var others = nearby(window).makeIterator()
        let assignments: [(FreeDesktopLayout.Snap, Int)] = slots.compactMap { slot in
            if slot == snap { return (slot, window) }
            if let assigned { return assigned[slot].flatMap { contains($0) && $0 != window ? (slot, $0) : nil } }
            return others.next().map { (slot, $0) }
        }
        let unit = CGRect(x: 0, y: 0, width: 6, height: 6)
        let groups = Dictionary(grouping: assignments) { FreeDesktopLayout.rect(for: $0.0, in: unit).minX }
        var result = self
        let chosen = Set(assignments.map(\.1))
        // Preserve every unchosen window and its relative order.
        for id in chosen { result.remove(id, in: metrics) }
        let insertion = min(source, result.columns.count)
        var arranged: [Column] = []
        var end: CGFloat = 0
        for x in groups.keys.sorted() {
            let group = groups[x]!.sorted {
                FreeDesktopLayout.rect(for: $0.0, in: unit).minY < FreeDesktopLayout.rect(for: $1.0, in: unit).minY
            }
            let fraction = FreeDesktopLayout.rect(for: group[0].0, in: unit).width / 6
            var column = Column(id: result.nextColumnID, window: group[0].1, width: fraction, pinned: true)
            result.nextColumnID += 1
            column.snapSized = true
            column.windows = group.map(\.1)
            column.heights = Self.even(group.count)
            column.leadingVacancy = max(0, x / 6 - end)
            if group.count == 1 {
                let slot = FreeDesktopLayout.rect(for: group[0].0, in: unit)
                if slot.height == 3 {
                    column.halfSlot = slot.minY == 0 ? 0 : 1
                }
            }
            end = x / 6 + fraction
            arranged.append(column)
        }
        if !arranged.isEmpty { arranged[arranged.count - 1].trailingVacancy = max(0, 1 - end) }
        result.columns.insert(contentsOf: arranged, at: insertion)
        result.focus(window)
        // Every chosen slot obeys the tile policy; the rest of the track is laid out again
        // around the arrangement.
        guard arranged.allSatisfy({ result.obeysPolicy($0, in: metrics) }) else { return nil }
        result.arrange(in: metrics)
        let frames = result.frames(in: metrics)
        for id in chosen {
            guard let frame = frames[id] else { return nil }
            // Native chrome must leave positive content space. App hints are applied
            // later by WindowSizePolicy.fitting, never by enlarging this target slot.
            guard frame.width > 0, frame.height > metrics.titleBar.height else { return nil }
        }
        return result
    }
}
