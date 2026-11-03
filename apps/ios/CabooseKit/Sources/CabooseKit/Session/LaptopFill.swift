import CoreGraphics

/// How Laptop's upper screen lays out its windows and keeps them there.
///
/// Every rect here is a window's content (below its title bar) in Linux pixels, as the
/// computer configures it. Laptop shows a snapped window fitted into its snap, so a window
/// keeps its snap's shape whatever size the app asks for, and a window whose minimum size
/// holds it larger than the screen takes the screen's shape, shown scaled to fit, rather
/// than a size that would leave the desktop showing beside it.
///
/// A window that fills the screen is configured maximized: the computer keeps it at its
/// frame while the app asks for another size, and the app knows it fills the screen. Every
/// window laid out at Laptop's frame rather than its own is also held there: one the app
/// resizes anyway (one that leaves the maximized state itself, or a half) is put back, once.
/// An app that leaves the layout again has refused it: its window keeps the app's own size,
/// shown fitted, and a relayout to the same frame leaves it be, until the owner lays it out
/// again (the green button, a snap) or the screen changes. Laptop never fights an app for a
/// window's size. A window that cannot take the frame exactly (one sized in character cells)
/// stays at the nearest size it takes.
public struct LaptopFill: Sendable {
    public struct Layout: Equatable, Sendable {
        public var frame: CGRect
        /// The window fills the screen and is configured maximized.
        public var maximized: Bool
        /// The frame is Laptop's, not the app's: the window is put back when it leaves it.
        public var held: Bool
        public init(frame: CGRect, maximized: Bool, held: Bool) {
            self.frame = frame; self.maximized = maximized; self.held = held
        }
    }

    /// How far, in pixels, a committed frame may stray from its layout and still be there:
    /// the computer rounds a frame to its logical pixels.
    public static let tolerance: CGFloat = 2

    private struct Hold: Sendable {
        var layout: Layout
        var seen: CGRect
        var restored = false
    }

    private var holds: [Int: Hold] = [:]
    /// Whether each window was last configured maximized, where that is known.
    private var configured: [Int: Bool] = [:]
    /// The layout frame each window's app refused, by leaving it after it was put back.
    private var refused: [Int: CGRect] = [:]

    public init() {}

    /// Where Laptop lays out a window placed at `placed` (the frame of its place, or its
    /// snap's) on a `screen` of content. A snapped window takes its snap's shape, grown to its
    /// minimum (`WindowSizePolicy.fitting`); `.maximized` fills the screen. An unsnapped window
    /// keeps its own frame unless its minimum holds it larger than the screen: one that can
    /// take the screen's shape then fills it as well, and one that cannot (a fixed size) keeps
    /// its own size. Nil for a frame that cannot be laid out.
    public static func layout(_ placed: CGRect, snap: FreeDesktopLayout.Snap?, screen: CGRect,
                              minimum: CGSize?, maximum: CGSize?) -> Layout? {
        if let snap {
            guard let fitted = WindowSizePolicy.fitting(placed, minimum: minimum, maximum: maximum,
                                                        fullscreen: false) else { return nil }
            return Layout(frame: WindowSizePolicy.centred(fitted, in: placed), maximized: snap == .maximized, held: true)
        }
        guard let own = WindowSizePolicy.request(placed, minimum: minimum, maximum: maximum,
                                                 fullscreen: false) else { return nil }
        guard exceeds(own.size, screen.size) else { return Layout(frame: placed, maximized: false, held: false) }
        guard WindowSizePolicy.fills(screen.size, minimum: minimum, maximum: maximum),
              let fitted = WindowSizePolicy.fitting(screen, minimum: minimum, maximum: maximum, fullscreen: false)
        else { return Layout(frame: own, maximized: false, held: false) }
        return Layout(frame: WindowSizePolicy.centred(fitted, in: screen), maximized: true, held: true)
    }

    /// The least content a window in a snap other than the whole screen is laid out at, in
    /// pixels: its own `minimum`, or the content of a usable window (`usable`, from
    /// `TilePolicy.required`), whichever is larger on each axis. A snap smaller than a usable
    /// window so still gets one, at the snap's shape, shown scaled down into it
    /// (`TilePolicy.fittedScale`).
    public static func snappedMinimum(_ minimum: CGSize?, usable: CGSize) -> CGSize {
        func valid(_ value: CGFloat?) -> CGFloat { value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0 }
        return CGSize(width: max(valid(minimum?.width), valid(usable.width)).rounded(.up),
                      height: max(valid(minimum?.height), valid(usable.height)).rounded(.up))
    }

    /// Whether a window of `size` is larger than the screen on either axis, beyond rounding.
    public static func exceeds(_ size: CGSize, _ screen: CGSize) -> Bool {
        size.width > screen.width + tolerance || size.height > screen.height + tolerance
    }

    /// Whether a window at `current` must be configured to take `layout`: it is elsewhere, or
    /// its maximized state is another or not known, and its app has not refused that layout.
    public func needsConfigure(_ id: Int, _ layout: Layout, current: CGRect) -> Bool {
        guard refused[id] != layout.frame else { return false }
        return current != layout.frame || configured[id] != layout.maximized
    }

    public func isMaximized(_ id: Int) -> Bool { configured[id] == true }

    public func hasRefused(_ id: Int) -> Bool { refused[id] != nil }

    /// The window is at `layout` while it is at `current`: `configured` to it now, which
    /// holds it there afresh, or already there, which keeps its hold, and a refused layout
    /// refused.
    public mutating func laidOut(_ id: Int, _ layout: Layout, current: CGRect, configured now: Bool = true) {
        if !now, refused[id] == layout.frame || holds[id]?.layout == layout { return }
        refused[id] = nil
        configured[id] = layout.maximized
        holds[id] = layout.held ? Hold(layout: layout, seen: current) : nil
    }

    /// The window was configured to a frame of the owner's, unmaximized: a drag or a resize.
    public mutating func release(_ id: Int) {
        holds[id] = nil
        refused[id] = nil
        configured[id] = false
    }

    /// Laptop opened or closed, and other layouts may have configured the windows since:
    /// nothing is held, and each window is configured again by its next layout.
    public mutating func reset() {
        holds.removeAll()
        configured.removeAll()
        refused.removeAll()
    }

    /// Keeps only these windows.
    public mutating func keep(_ ids: Set<Int>) {
        holds = holds.filter { ids.contains($0.key) }
        configured = configured.filter { ids.contains($0.key) }
        refused = refused.filter { ids.contains($0.key) }
    }

    public func isHeld(_ id: Int) -> Bool { holds[id] != nil }

    /// The window has committed `frame`. Returns the layout to configure it to again the
    /// first time the app resizes it off its layout; the second time, the app has refused the
    /// layout, and the window is let go.
    public mutating func restore(_ id: Int, committed frame: CGRect) -> Layout? {
        guard var hold = holds[id] else { return nil }
        let changed = !Self.near(frame, hold.seen)
        hold.seen = frame
        guard changed, !Self.near(frame, hold.layout.frame) else { holds[id] = hold; return nil }
        guard !hold.restored else {
            holds[id] = nil
            refused[id] = hold.layout.frame
            return nil
        }
        hold.restored = true
        holds[id] = hold
        return hold.layout
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
