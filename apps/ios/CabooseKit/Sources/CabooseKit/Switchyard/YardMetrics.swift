import CoreGraphics

/// The screen Switchyard lays out for, and the sizes that follow from it.
///
/// Column widths are fractions of the screen, chosen from ⅓, ½, ⅔ and full. A preset is
/// offered only where its column is at least `minimumTile` wide and two halves fit, so an
/// iPhone held upright offers full width alone, a Duo opened out or a phone on its side adds
/// halves and two thirds, and an iPad adds thirds. The gap between tiles is the same at the screen's edges.
public struct YardMetrics: Equatable, Sendable {
    /// The space for the yard, in points.
    public var size: CGSize
    public var gap: CGFloat

    /// The narrowest a tile is made: about what a Linux app can lay out in at the yard's
    /// density, and narrow enough that an iPhone Duo opened out takes two side by side.
    public static let minimumTile = CGSize(width: 280, height: 180)
    public var minimumTile: CGSize { Self.minimumTile }

    public static let fractions: [CGFloat] = [1.0 / 3, 0.5, 2.0 / 3, 1]

    public init(size: CGSize, gap: CGFloat? = nil) {
        self.size = size
        self.gap = gap ?? Self.gap(forWidth: size.width)
    }

    /// Tighter on a phone, where every point counts.
    public static func gap(forWidth width: CGFloat) -> CGFloat { width < 500 ? 3 : 4 }

    /// Tile corners: rounded like the system's own windows, kept small so they cost no
    /// content.
    public var cornerRadius: CGFloat { size.width < 500 ? 10 : 12 }

    public var columnHeight: CGFloat { max(0, size.height - 2 * gap) }

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

    /// How many windows a column stacks: two on a phone held upright, three elsewhere.
    public var maxStack: Int { size.height < 500 || size.width < 500 ? 2 : 3 }

    /// A column `fraction` of the screen wide, in points. Fractions add up: two halves and
    /// their three gaps fill the screen exactly.
    public func points(forFraction fraction: CGFloat) -> CGFloat {
        max(0, fraction * (size.width - gap) - gap)
    }

    public func fraction(forPoints points: CGFloat) -> CGFloat {
        guard size.width > gap else { return 1 }
        return (points + gap) / (size.width - gap)
    }

    /// The narrowest fraction that still makes a tile `minimumTile` wide. A screen too narrow
    /// for two halves side by side keeps every column full width: a column that leaves too
    /// little beside it for another only wastes the rest.
    public var minimumFraction: CGFloat {
        guard points(forFraction: 0.5) >= minimumTile.width else { return 1 }
        return min(1, fraction(forPoints: minimumTile.width))
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
