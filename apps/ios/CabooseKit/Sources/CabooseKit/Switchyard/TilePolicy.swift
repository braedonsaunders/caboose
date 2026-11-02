import CoreGraphics
import Foundation

/// The rules every tiled window obeys, on every screen, with any set of windows.
///
/// - A tile is never smaller than a usable desktop window: `floor` (title bar included), or
///   the window's own minimum content plus its title bar, whichever is larger. A screen
///   smaller than that gives the window the whole screen in that direction instead.
/// - A tile that shares the screen keeps a sensible shape: between `aspects` wide to high.
///   A window alone on the screen takes the screen's own shape, whatever it is.
/// - Windows that share a screen are split by its shape. Each candidate arrangement (one
///   column, side by side, stacked, a grid, a large window beside a stack) is tried, every
///   tile is checked against the two rules above, and of those that pass the one whose
///   tiles are closest to an ordinary window's shape (`idealAspect`) wins. A tall screen so
///   stacks, a wide one sits side by side, and a grid appears only where every cell passes.
/// - Windows that do not all fit on one screen are never squeezed: the screen takes as many
///   as fit, and the rest fill further screens along Switchyard's track, reached by swiping,
///   the dock, Overview or Quick Switch.
///
/// Dialogs, menus and other windows that belong to another are never tiled: they float at
/// their own size, centred over their parent (`dialogFrame`). A window in full screen,
/// asked for by the app or chosen by the person, covers the workspace instead of its tile.
///
/// Sizes are in points. Nothing here knows about any particular app.
public enum TilePolicy {
    /// The smallest tile a desktop window gets, title bar included: about the smallest
    /// window an ordinary desktop app lays out well in.
    public static let floor = CGSize(width: 560, height: 400)
    /// Width over height for a tile that shares the screen.
    public static let aspects: ClosedRange<CGFloat> = 0.55...4
    /// The shape arrangements aim for: a typical desktop window, a little wider than high.
    public static let idealAspect: CGFloat = 1.4
    /// The most columns, and windows stacked in a column, one screen holds.
    public static let maximumColumns = 4
    public static let maximumRows = 3
    /// Rounding slack, in points: tiles are whole points and shares are fractions.
    static let slack: CGFloat = 1

    // MARK: Single tiles

    /// The least tile a window takes in `area`: the floor, or its own minimum content
    /// (`minimum`, points) below a `titleBar` high bar, whichever is larger; never more than
    /// the area itself, where a larger window is shown whole, scaled to fit.
    public static func required(minimum: CGSize?, titleBar: CGFloat, in area: CGSize,
                                floor: CGSize = floor) -> CGSize {
        func valid(_ value: CGFloat?) -> CGFloat { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0 }
        let width = max(floor.width, valid(minimum?.width))
        let height = max(floor.height, valid(minimum?.height) + titleBar)
        return CGSize(width: max(0, min(width, area.width)), height: max(0, min(height, area.height)))
    }

    /// Whether a `tile` obeys the rules for a window that needs `required`, in `area`.
    public static func allows(_ tile: CGSize, required: CGSize, in area: CGSize) -> Bool {
        guard tile.width + slack >= required.width, tile.height + slack >= required.height,
              tile.width > 0, tile.height > 0 else { return false }
        // Alone on the screen: the screen's own shape.
        if tile.width + slack >= area.width, tile.height + slack >= area.height { return true }
        return aspects.contains(tile.width / tile.height)
    }

    // MARK: Arrangements

    /// What the arranger places: a lone window, which it may stack with its neighbours; or a
    /// column the person made (`kept`), kept whole in a column of its own: a stack
    /// (`windows`, with the person's `heights` where they dragged the split) or a window
    /// they moved apart, and a width they picked (`width`, a fraction of the screen already
    /// fitted to this screen).
    public struct Unit: Equatable, Sendable {
        public var windows: [Int]
        public var width: CGFloat?
        public var heights: [CGFloat]?
        public var kept: Bool

        public init(windows: [Int], width: CGFloat? = nil, heights: [CGFloat]? = nil, kept: Bool = false) {
            self.windows = windows
            self.width = width
            self.heights = heights
            self.kept = kept || windows.count > 1
        }

        public static func window(_ id: Int) -> Unit { Unit(windows: [id]) }

        /// Kept whole in a column of its own.
        public var isFixed: Bool { kept || width != nil }
    }

    /// One column of an arrangement: its windows top to bottom, its width as a fraction of
    /// the screen, each window's share of the column's height, and whether it is a unit the
    /// person made (`pinned`: their width; `kept`: their column).
    public struct Column: Equatable, Sendable {
        public var windows: [Int]
        public var width: CGFloat
        public var heights: [CGFloat]
        public var pinned = false
        public var kept = false
    }

    /// The best arrangement of all of `windows`, in order, on one screen of `metrics`, or nil
    /// when they cannot all share it.
    public static func screenful(_ windows: [Int], in metrics: YardMetrics) -> [Column]? {
        screenful(windows.map(Unit.window), in: metrics)
    }

    /// The best arrangement of all of `units`, in order, on one screen, or nil when they
    /// cannot all share it.
    public static func screenful(_ units: [Unit], in metrics: YardMetrics) -> [Column]? {
        let count = units.reduce(0) { $0 + $1.windows.count }
        guard !units.isEmpty, count <= maximumColumns * maximumRows else { return nil }
        var best: (cost: CGFloat, columns: [Column])?
        for split in columnSplits(units) {
            guard let candidate = arrangement(units, split: split, in: metrics) else { continue }
            if best == nil || candidate.cost < best!.cost - 0.000_001 { best = candidate }
        }
        return best?.columns
    }

    /// `windows`, in order, over as many screens as they need.
    public static func screenfuls(_ windows: [Int], in metrics: YardMetrics) -> [[Column]] {
        screenfuls(windows.map(Unit.window), in: metrics)
    }

    /// `units`, in order, over as many screens as they need: each screen takes as many of the
    /// next units as can share it, in their best arrangement.
    public static func screenfuls(_ units: [Unit], in metrics: YardMetrics) -> [[Column]] {
        var result: [[Column]] = []
        var rest = units[...]
        while let first = rest.first {
            var taken = false
            for count in stride(from: min(rest.count, maximumColumns * maximumRows), through: 1, by: -1) {
                if let columns = screenful(Array(rest.prefix(count)), in: metrics) {
                    result.append(columns)
                    rest = rest.dropFirst(count)
                    taken = true
                    break
                }
            }
            // A unit that cannot fit even alone is the caller's to release; shown alone, it
            // is never squeezed beside another.
            if !taken {
                result.append([Column(windows: first.windows, width: first.width ?? 1,
                                      heights: first.heights ?? YardLayout.even(first.windows.count),
                                      pinned: first.width != nil, kept: first.kept)])
                rest = rest.dropFirst()
            }
        }
        return result
    }

    /// Every way to put `units`, in order, into columns: a fixed unit alone, lone windows a
    /// few to a column.
    static func columnSplits(_ units: [Unit]) -> [[Range<Int>]] {
        var result: [[Range<Int>]] = []
        func extend(_ prefix: [Range<Int>], from start: Int) {
            if start == units.count { result.append(prefix); return }
            guard prefix.count < maximumColumns else { return }
            if units[start].isFixed { extend(prefix + [start..<(start + 1)], from: start + 1); return }
            var end = start
            while end < units.count, !units[end].isFixed, end - start < maximumRows {
                end += 1
                extend(prefix + [start..<end], from: end)
            }
        }
        extend([], from: 0)
        return result
    }

    private static func arrangement(_ units: [Unit], split: [Range<Int>],
                                    in metrics: YardMetrics) -> (cost: CGFloat, columns: [Column])? {
        let area = metrics.area
        let available = area.width - metrics.gap * CGFloat(split.count - 1)
        guard available > 0 else { return nil }
        // Widths: a picked width is kept; the other columns share the rest as evenly as their
        // windows allow.
        var widths = Array(repeating: CGFloat(0), count: split.count)
        var free: [Int] = []
        for (index, range) in split.enumerated() {
            if let fraction = units[range.lowerBound].width {
                widths[index] = metrics.points(forFraction: fraction)
            } else {
                free.append(index)
            }
        }
        let room = available - widths.reduce(0, +)
        if free.isEmpty {
            // Picked widths alone may leave part of the screen to the next unit on the track,
            // but never overrun it.
            guard split.count == 1 || room >= -slack else { return nil }
        } else {
            let minimums = free.map { index in
                split[index].flatMap { units[$0].windows }.map { metrics.required($0).width }.max() ?? 0
            }
            guard let shares = shares(room, gap: 0, minimums: minimums) else { return nil }
            for (index, share) in zip(free, shares) { widths[index] = room * share }
        }
        var columns: [Column] = []
        var cost: CGFloat = 0
        for (range, width) in zip(split, widths) {
            let windows = range.flatMap { units[$0].windows }
            let unit = units[range.lowerBound]
            let required = windows.map { metrics.required($0) }
            var heights = unit.windows.count > 1 ? unit.heights : nil
            if let chosen = heights, !tiles(width: width, heights: chosen, required: required, in: metrics) { heights = nil }
            if heights == nil { heights = shares(area.height, gap: metrics.gap, minimums: required.map(\.height)) }
            guard let heights, heights.count == windows.count,
                  tiles(width: width, heights: heights, required: required, in: metrics) else { return nil }
            let rect = CGRect(x: 0, y: 0, width: width, height: area.height)
            for tile in YardLayout.split(rect, heights: heights, gap: metrics.gap) {
                cost += abs(log(tile.width / tile.height / idealAspect))
            }
            columns.append(Column(windows: windows, width: unit.width ?? metrics.fraction(forPoints: width), heights: heights,
                                  pinned: unit.width != nil, kept: unit.kept))
        }
        // The last shared column takes what rounding leaves, so a screen ends exactly where
        // the next begins.
        if let last = free.last {
            let used = columns.indices.filter { $0 != last }.reduce(CGFloat(0)) { $0 + columns[$1].width }
            columns[last].width = max(0, 1 - used)
        }
        return (cost, columns)
    }

    /// Whether a column `width` wide split by `heights` gives every window a tile it accepts.
    private static func tiles(width: CGFloat, heights: [CGFloat], required: [CGSize], in metrics: YardMetrics) -> Bool {
        guard heights.count == required.count else { return false }
        let rect = CGRect(x: 0, y: 0, width: width, height: metrics.area.height)
        return zip(YardLayout.split(rect, heights: heights, gap: metrics.gap), required).allSatisfy {
            allows($0.size, required: $1, in: metrics.area)
        }
    }

    /// Each window's share of `total` points split `count` ways with `gap` between: as even
    /// as the windows' minimums allow. Nil when the minimums do not fit.
    static func shares(_ total: CGFloat, gap: CGFloat, minimums: [CGFloat]) -> [CGFloat]? {
        let available = total - gap * CGFloat(max(0, minimums.count - 1))
        guard !minimums.isEmpty, available > 0, minimums.reduce(0, +) <= available + slack else { return nil }
        var sizes = Array(repeating: CGFloat(0), count: minimums.count)
        var fixed = Set<Int>()
        while true {
            let free = minimums.indices.filter { !fixed.contains($0) }
            guard !free.isEmpty else { break }
            let each = (available - fixed.reduce(0) { $0 + sizes[$1] }) / CGFloat(free.count)
            let raised = free.filter { minimums[$0] > each }
            if raised.isEmpty {
                for index in free { sizes[index] = each }
                break
            }
            for index in raised { sizes[index] = minimums[index]; fixed.insert(index) }
        }
        return sizes.map { $0 / available }
    }

    // MARK: Floating windows

    /// Where a dialog or other window belonging to another sits: at its own size (`natural`),
    /// centred over its parent's rect (`parent`, else the whole `bounds`), kept `margin`
    /// inside `bounds` and made smaller only when `bounds` is.
    public static func dialogFrame(natural: CGSize, parent: CGRect?, in bounds: CGRect, margin: CGFloat = 12) -> CGRect {
        let width = max(1, min(natural.width, bounds.width - 2 * margin))
        let height = max(1, min(natural.height, bounds.height - 2 * margin))
        let around = parent ?? bounds
        var origin = CGPoint(x: around.midX - width / 2, y: around.midY - height / 2)
        origin.x = max(bounds.minX + margin, min(origin.x, bounds.maxX - margin - width))
        origin.y = max(bounds.minY + margin, min(origin.y, bounds.maxY - margin - height))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
