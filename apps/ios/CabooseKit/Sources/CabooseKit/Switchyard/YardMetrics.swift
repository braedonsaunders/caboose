import CoreGraphics

/// The screen Switchyard lays out for, and the sizes that follow from it.
///
/// Column widths are fractions of the screen. A width the person picks is one of ⅓, ½, ⅔
/// and full, offered only where a lone window in it obeys `TilePolicy` (at least the floor
/// wide, and not too narrow for its height), so an iPhone, an iPhone Duo's inner screen
/// held upright or an upright iPad offers full width alone, and a wide iPad or a TV adds
/// halves, two thirds and, where they fit, thirds. Resize gaps separate tiles; the outer
/// edges meet the workspace.
public struct YardMetrics: Equatable, Sendable {
    /// The space for the yard, in points.
    public var size: CGSize
    public var gap: CGFloat
    public var outerGap: CGFloat
    /// Each window's own minimum content size, in points, where it has one.
    public var minimums: [Int: CGSize]

    /// The smallest tile a window is given: `TilePolicy.floor`.
    public static let minimumTile = TilePolicy.floor
    public var minimumTile: CGSize { Self.minimumTile }

    public static let fractions: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]

    public init(size: CGSize, gap: CGFloat? = nil, outerGap: CGFloat = 0, minimums: [Int: CGSize] = [:]) {
        self.size = size
        self.outerGap = max(0, outerGap)
        self.gap = gap ?? Self.gap(forWidth: size.width)
        self.minimums = minimums
    }

    /// The tiled area: the screen inside its outer margins.
    public var area: CGSize { CGSize(width: max(0, size.width - 2 * outerGap), height: columnHeight) }

    /// The least tile `window` takes on this screen (`TilePolicy.required`).
    public func required(_ window: Int) -> CGSize {
        TilePolicy.required(minimum: minimums[window], titleBar: titleBar.height, in: area)
    }

    /// Tighter on a phone, where every point counts.
    public static func gap(forWidth width: CGFloat) -> CGFloat { width < 500 ? 3 : 4 }

    /// Tile corners: rounded like the system's own windows, kept small so they cost no
    /// content.
    public var cornerRadius: CGFloat { size.width < 500 ? 10 : 12 }

    public var columnHeight: CGFloat { max(0, size.height - 2 * outerGap) }

    /// The title bar at the top of every tile: Close and Full Screen, then the title. A tiled
    /// window has no minimized state, so there is no Minimize.
    public static let titleBar = WindowTitleBar(touch: true, controls: [.close, .zoom])
    public var titleBar: WindowTitleBar { Self.titleBar }

    /// The part of a tile the window itself fills, below its title bar. This, not the tile,
    /// is the window's Linux geometry and where its input and popups are placed.
    public func content(ofTile tile: CGRect) -> CGRect {
        let bar = min(titleBar.height, tile.height)
        return CGRect(x: tile.minX, y: tile.minY + bar, width: tile.width, height: tile.height - bar)
    }

    /// A column `fraction` of the screen wide, in points. Fractions add up: two halves and
    /// their interior gap and outer margins fill the screen exactly.
    public func points(forFraction fraction: CGFloat) -> CGFloat {
        max(0, fraction * (size.width - 2 * outerGap + gap) - gap)
    }

    public func fraction(forPoints points: CGFloat) -> CGFloat {
        guard size.width - 2 * outerGap + gap > 0 else { return 1 }
        return (points + gap) / (size.width - 2 * outerGap + gap)
    }

    /// The narrowest fraction a lone window's column may take: at least the floor wide and
    /// no narrower than `TilePolicy.aspects` allows for the column's height. A screen too
    /// narrow for two such columns side by side keeps every column full width: a column that
    /// leaves too little beside it for another only wastes the rest.
    public var minimumFraction: CGFloat {
        let floor = TilePolicy.required(minimum: nil, titleBar: 0, in: area).width
        let narrowest = max(floor, TilePolicy.aspects.lowerBound * columnHeight)
        guard points(forFraction: 0.5) + TilePolicy.slack >= narrowest else { return 1 }
        return min(1, fraction(forPoints: narrowest - TilePolicy.slack))
    }

    /// The widths this screen offers, narrowest first. Full width is always one.
    public var presets: [CGFloat] { Self.fractions.filter { $0 >= minimumFraction - 0.0001 } }

    /// What a stored width becomes on this screen: itself where it fits, else the narrowest
    /// preset that does.
    public func effectiveFraction(_ fraction: CGFloat) -> CGFloat {
        if fraction >= minimumFraction - 0.0001 { return min(1, fraction) }
        return presets.first ?? 1
    }

    /// How many columns of the narrowest preset fit side by side.
    public var columnsInView: Int { max(1, Int((1 / (presets.first ?? 1)).rounded())) }
}
