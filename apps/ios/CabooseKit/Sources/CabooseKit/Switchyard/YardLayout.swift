import CoreGraphics
import Foundation

/// Switchyard's layout: the computer's windows tiled on one horizontal track of columns.
///
/// Every column is as tall as the screen and holds one window, or a few stacked. The track
/// can be wider than the screen; the screen shows a stretch of it and scrolls along it, so a
/// new window takes a column of its own instead of halving the one beside it. Widths are
/// fractions of the screen and heights fractions of the column, so the same layout carries
/// across rotation, a fold or Split View and only the number of columns in view changes.
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

        init(id: Int, window: Int, width: CGFloat, pinned: Bool) {
            self.id = id
            windows = [window]
            heights = [1]
            self.width = width
            self.pinned = pinned
        }
    }

    public private(set) var columns: [Column] = []
    /// The window that takes the keyboard.
    public private(set) var focused: Int?
    private var nextColumnID = 1

    public init() {}

    // MARK: Reading

    public var windows: [Int] { columns.flatMap(\.windows) }
    public var isEmpty: Bool { columns.isEmpty }
    public func contains(_ window: Int) -> Bool { columnIndex(of: window) != nil }

    public func columnIndex(of window: Int) -> Int? { columns.firstIndex { $0.windows.contains(window) } }

    public func column(id: Int) -> Column? { columns.first { $0.id == id } }

    public var focusedColumnIndex: Int? { focused.flatMap(columnIndex(of:)) }

    // MARK: Geometry

    /// The column's width on this screen, in points. A width too narrow for this screen
    /// becomes the narrowest preset that fits, so folding a phone never leaves a sliver.
    public func width(of column: Column, in metrics: YardMetrics) -> CGFloat {
        metrics.points(forFraction: metrics.effectiveFraction(column.width))
    }

    /// Each column's rect on the track.
    public func columnFrames(in metrics: YardMetrics) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        var x = metrics.outerGap
        for column in columns {
            let width = width(of: column, in: metrics)
            let stride = metrics.size.width - 2 * metrics.outerGap + metrics.gap
            let preservesSlots = column.width >= metrics.minimumFraction - 0.0001
            x += preservesSlots ? (column.leadingVacancy ?? 0) * stride : 0
            var frame = CGRect(x: x, y: metrics.outerGap, width: width, height: metrics.columnHeight)
            if let slot = column.halfSlot, (0...1).contains(slot),
               (metrics.columnHeight - metrics.gap) / 2 >= metrics.minimumTile.height {
                frame = Self.split(frame, heights: [0.5, 0.5], gap: metrics.gap)[slot]
            }
            frames[column.id] = frame
            x += width + metrics.gap + (preservesSlots ? (column.trailingVacancy ?? 0) * stride : 0)
        }
        return frames
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
            let vacancy = column.width >= metrics.minimumFraction - 0.0001
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

    /// Adds a window in a column of its own to the right of the focused column (or at the end)
    /// and focuses it. `width` is a remembered width for the app, which pins the column.
    public mutating func insert(_ window: Int, width: CGFloat? = nil, in metrics: YardMetrics) {
        guard !contains(window) else { return }
        let index = focusedColumnIndex.map { $0 + 1 } ?? columns.count
        let column = Column(id: nextColumnID, window: window, width: width ?? 1, pinned: width != nil)
        nextColumnID += 1
        columns.insert(column, at: index)
        focused = window
        share(in: metrics)
    }

    /// Adds a window under another one, in its column, when the column has room.
    @discardableResult
    public mutating func insert(_ window: Int, below other: Int, in metrics: YardMetrics) -> Bool {
        guard !contains(window), let index = columnIndex(of: other),
              columns[index].windows.count < metrics.maxStack,
              let position = columns[index].windows.firstIndex(of: other) else { return false }
        columns[index].windows.insert(window, at: position + 1)
        columns[index].heights = Self.even(columns[index].windows.count)
        columns[index].halfSlot = nil
        focused = window
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
        share(in: metrics)
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
        }
    }

    /// Takes off the track every window that no longer exists.
    public mutating func prune(keeping windows: Set<Int>, in metrics: YardMetrics) {
        for window in self.windows where !windows.contains(window) { remove(window, in: metrics) }
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
            return true
        case .left, .right:
            if columns[index].windows.count > 1 {
                return move(window, to: .column(direction == .left ? index : index + 1), in: metrics)
            }
            let target = direction == .left ? index - 1 : index + 1
            guard columns.indices.contains(target) else { return false }
            columns.swapAt(index, target)
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
                columns.insert(Column(id: nextColumnID, window: window, width: 1, pinned: false), at: min(index, columns.count))
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
            guard columns[columnIndex].windows.count < metrics.maxStack else { return false }
            detach(window, column: from, position: position)
            guard let target = columns.firstIndex(where: { $0.id == targetID }) else { return false }
            columns[target].windows.insert(window, at: min(at, columns[target].windows.count))
            columns[target].heights = Self.even(columns[target].windows.count)
            columns[target].halfSlot = nil
        }
        focused = window
        share(in: metrics)
        return true
    }

    // MARK: Sizes

    /// Sets a column's width, as a fraction of the screen, and pins it.
    public mutating func setWidth(_ fraction: CGFloat, column id: Int, in metrics: YardMetrics) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        columns[index].width = min(1, max(metrics.minimumFraction, fraction))
        columns[index].pinned = true
    }

    /// Sets a column's width from a drag, in points, without snapping.
    public mutating func drag(column id: Int, toWidth points: CGFloat, in metrics: YardMetrics) {
        setWidth(metrics.fraction(forPoints: points), column: id, in: metrics)
    }

    /// Lets go of a width drag: the column settles on the nearest preset.
    public mutating func snapWidth(column id: Int, velocity: CGFloat = 0, in metrics: YardMetrics) {
        guard let column = column(id: id) else { return }
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
            columns[index].pinned = false
            share(in: metrics)
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
        let minimum = min(pair / 2, metrics.minimumTile.height / available)
        let upper = min(max(minimum, columns[index].heights[position] + delta / available), pair - minimum)
        columns[index].heights[position] = upper
        columns[index].heights[position + 1] = pair - upper
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

    /// Unpinned columns share the screen evenly while they all fit on it, as many as the
    /// screen's narrowest preset allows; beyond that each new one is a column the track
    /// scrolls to. Pinned columns keep their width.
    mutating func share(in metrics: YardMetrics) {
        let loose = columns.indices.filter { !columns[$0].pinned }
        guard !loose.isEmpty else { return }
        let pinnedWidth = columns.filter(\.pinned).reduce(0) { $0 + metrics.effectiveFraction($1.width) + ($1.width >= metrics.minimumFraction - 0.0001 ? ($1.leadingVacancy ?? 0) + ($1.trailingVacancy ?? 0) : 0) }
        let room = 1 - pinnedWidth
        let each = room / CGFloat(loose.count)
        // The widest preset that gives each loose column an even share; once they no longer
        // fit, the narrowest, and the track scrolls.
        let fitting = metrics.presets.filter { $0 <= each + 0.001 }.max() ?? metrics.presets.first ?? 1
        for index in loose { columns[index].width = fitting }
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
                let room = column.windows.count < metrics.maxStack || index == from
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
    /// A proposed native palette arrangement, expressed entirely as ordinary Yard columns.
    /// The source stays untouched until release. Unfilled slots reserve space in the
    /// existing column geometry; they do not create windows or a second layout engine.
    public func snapping(_ window: Int, to snap: FreeDesktopLayout.Snap,
                         layout slots: [FreeDesktopLayout.Snap], in metrics: YardMetrics,
                         minimums: [Int: CGSize] = [:]) -> YardLayout? {
        guard let source = columnIndex(of: window), slots.contains(snap),
              Set(slots).count == slots.count else { return nil }
        let ordered = Array(columns[source...].flatMap(\.windows)) + columns[..<source].flatMap(\.windows)
        var others = ordered.filter { $0 != window }.makeIterator()
        let assignments: [(FreeDesktopLayout.Snap, Int)] = slots.compactMap { slot in
            guard let id = slot == snap ? window : others.next() else { return nil }
            return (slot, id)
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
            guard fraction >= metrics.minimumFraction - 0.0001 else { return nil }
            var column = Column(id: result.nextColumnID, window: group[0].1, width: fraction, pinned: true)
            result.nextColumnID += 1
            column.windows = group.map(\.1)
            column.heights = Self.even(group.count)
            column.leadingVacancy = max(0, x / 6 - end)
            if group.count == 1 {
                let slot = FreeDesktopLayout.rect(for: group[0].0, in: unit)
                if slot.height == 3 {
                    guard (metrics.columnHeight - metrics.gap) / 2 >= metrics.minimumTile.height else { return nil }
                    column.halfSlot = slot.minY == 0 ? 0 : 1
                }
            }
            end = x / 6 + fraction
            arranged.append(column)
        }
        if !arranged.isEmpty { arranged[arranged.count - 1].trailingVacancy = max(0, 1 - end) }
        result.columns.insert(contentsOf: arranged, at: insertion)
        result.focus(window)
        let frames = result.frames(in: metrics)
        for id in chosen {
            guard let frame = frames[id] else { return nil }
            let minimum = minimums[id] ?? .zero
            guard frame.width >= max(metrics.minimumTile.width, minimum.width),
                  frame.height >= max(metrics.minimumTile.height, minimum.height) else { return nil }
        }
        return result
    }
}
