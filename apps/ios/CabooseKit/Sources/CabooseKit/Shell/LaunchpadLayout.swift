import CoreGraphics

/// The Launchpad grid for a desktop of a given size: columns of at most 150 points (scaled by
/// the desktop's size factor `ui`), as many as the width holds up to seven and at least two,
/// and as many rows as fit above the dock. It always fits inside the desktop, so a phone's
/// narrow screen beside its bars gets fewer, narrower columns rather than an overflow.
public struct LaunchpadLayout: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var column: CGFloat
    public var icon: CGFloat
    public var spacing: CGFloat
    public var top: CGFloat

    public init(size: CGSize, ui: CGFloat, dockHeight: CGFloat) {
        spacing = 28 * ui
        let margin = 24 * ui
        let width = max(1, size.width - 2 * margin)
        columns = min(7, max(2, Int((width + spacing) / (150 * ui + spacing))))
        column = max(1, min(150 * ui, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)))
        icon = min(84 * ui, column * 0.78)
        top = 60 * ui
        let rowHeight = icon + 8 * ui + 20 * ui + spacing
        rows = max(1, Int((size.height - top - dockHeight - 40 * ui) / rowHeight))
    }

    /// The grid's width, spacing included.
    public var width: CGFloat { CGFloat(columns) * column + CGFloat(columns - 1) * spacing }

    public func pageRange(_ page: Int, count: Int) -> Range<Int> {
        let capacity = max(1, columns * rows)
        let last = max(0, (max(0, count) - 1) / capacity)
        let start = min(max(0, page), last) * capacity
        return start..<min(max(0, count), start + capacity)
    }
}
