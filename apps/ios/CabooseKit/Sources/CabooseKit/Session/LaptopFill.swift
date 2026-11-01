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
/// resizes anyway (one that leaves the maximized state itself, or a half) is put back. A
/// window that cannot take the frame exactly (one sized in character cells) stays at the
/// nearest size it takes, and one the app keeps resizing is put back at most `restores`
/// times in `period` seconds.
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

    public static let restores = 3
    public static let period: Double = 10
    /// How far, in pixels, a committed frame may stray from its layout and still be there:
    /// the computer rounds a frame to its logical pixels.
    public static let tolerance: CGFloat = 2

    private struct Hold: Sendable {
        var layout: Layout
        var seen: CGRect
        var restored: [Double]
    }

    private var holds: [Int: Hold] = [:]
    /// The windows last configured maximized, until they are configured otherwise.
    public private(set) var maximized: Set<Int> = []

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

    /// Whether a window of `size` is larger than the screen on either axis, beyond rounding.
    public static func exceeds(_ size: CGSize, _ screen: CGSize) -> Bool {
        size.width > screen.width + tolerance || size.height > screen.height + tolerance
    }

    /// Whether a window at `current` must be configured to take `layout`.
    public func needsConfigure(_ id: Int, _ layout: Layout, current: CGRect) -> Bool {
        current != layout.frame || maximized.contains(id) != layout.maximized
    }

    /// The window was configured to `layout` while it was at `current`.
    public mutating func laidOut(_ id: Int, _ layout: Layout, current: CGRect) {
        if layout.maximized { maximized.insert(id) } else { maximized.remove(id) }
        guard layout.held else { holds[id] = nil; return }
        holds[id] = Hold(layout: layout, seen: current, restored: holds[id]?.restored ?? [])
    }

    /// The window was configured to a frame of the owner's, unmaximized: a drag or a resize.
    public mutating func release(_ id: Int) {
        holds[id] = nil
        maximized.remove(id)
    }

    /// Laptop closed: nothing is held, and the maximized windows are still known, so the
    /// next layout configures them otherwise.
    public mutating func releaseAll() { holds.removeAll() }

    /// Keeps only these windows.
    public mutating func keep(_ ids: Set<Int>) {
        holds = holds.filter { ids.contains($0.key) }
        maximized.formIntersection(ids)
    }

    public func isHeld(_ id: Int) -> Bool { holds[id] != nil }

    /// The window has committed `frame` at `now` (seconds). Returns the layout to configure it
    /// to again when the app has resized it off its layout since it was last seen.
    public mutating func restore(_ id: Int, committed frame: CGRect, now: Double) -> Layout? {
        guard var hold = holds[id] else { return nil }
        defer { holds[id] = hold }
        let changed = !Self.near(frame, hold.seen)
        hold.seen = frame
        guard changed, !Self.near(frame, hold.layout.frame) else { return nil }
        hold.restored.removeAll { now - $0 >= Self.period }
        guard hold.restored.count < Self.restores else { return nil }
        hold.restored.append(now)
        return hold.layout
    }

    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
