import CoreGraphics
import Foundation

/// Where windows sit on the floating desktop (a TV, or an iPad set to Free), as the owner
/// placed them.
///
/// Every rect here is a window's whole frame in desktop points, title bar included, inside
/// the desktop's work area (the desktop above the dock). A place keeps the frame the owner
/// last chose by hand and the work area it was chosen in, and every other size of the
/// desktop is derived from that pair. A rotation, a TV or a zoom change therefore never
/// compounds: going back to the original area gives back the original frame exactly.
///
/// Window ids survive reconnects and parking, so places are kept by id between launches.
/// Each also records its window's app class, and applies only to a window of exactly that
/// class, never to another app's or to one whose class is not known: after a cold boot an id
/// can name another window. Once the computer has announced its windows, places of windows it
/// no longer has are dropped (`prune`).
public struct FreeDesktopLayout: Codable, Equatable, Sendable {
    /// A side, a corner or the whole work area, which the window keeps as the area changes.
    public enum Snap: String, Codable, Sendable, CaseIterable {
        case left, right, maximized, topLeft, topRight, bottomLeft, bottomRight
    }

    public struct Place: Codable, Equatable, Sendable {
        /// The frame last chosen by hand, in the work area `area`.
        public var preferred: CGRect
        /// The work area `preferred` was chosen in.
        public var area: CGRect
        /// The window is snapped; it returns to `preferred` when it leaves the snap.
        public var snap: Snap?
        /// The window's app class, lowercased, when it had one.
        public var app: String?
        /// The window was minimized to the dock.
        public var minimized: Bool?
        /// When the place was last changed, as an ever-increasing count.
        public var touched: Int
    }

    /// The most places kept; the least recently changed go first.
    public static let capacity = 64

    public private(set) var places: [Int: Place] = [:]
    private var clock = 0

    public init() {}

    public func place(for id: Int, app: String?) -> Place? {
        guard let place = places[id], let app, place.app == app.lowercased() else { return nil }
        return place
    }

    public func snap(of id: Int) -> Snap? { places[id]?.snap }
    public func isMinimized(_ id: Int, app: String?) -> Bool { place(for: id, app: app)?.minimized == true }

    /// Where the window belongs in `area`, if it has a place.
    public func frame(for id: Int, app: String?, in area: CGRect, minimum: CGSize = .zero) -> CGRect? {
        guard let place = place(for: id, app: app) else { return nil }
        if let snap = place.snap { return Self.rect(for: snap, in: area, minimum: minimum) }
        return Self.refit(place.preferred, from: place.area, to: area, minimum: minimum)
    }

    /// The owner moved or resized the window to `frame`: it is the window's frame now, unsnapped.
    public mutating func setPreferred(_ id: Int, frame: CGRect, in area: CGRect, app: String?) {
        clock += 1
        let minimized = places[id]?.minimized
        places[id] = Place(preferred: frame, area: area, snap: nil, app: app?.lowercased(), minimized: minimized, touched: clock)
        trim()
    }

    /// Snaps the window, keeping the frame it returns to. `current` is where it is now, used
    /// as that frame when it has no place yet.
    public mutating func setSnap(_ id: Int, _ snap: Snap?, current: CGRect, in area: CGRect, app: String?) {
        clock += 1
        var place = self.place(for: id, app: app)
            ?? Place(preferred: current, area: area, snap: nil, app: app?.lowercased(), touched: clock)
        place.snap = snap
        place.touched = clock
        places[id] = place
        trim()
    }

    /// Minimizes the window to the dock, or brings it back; a window without a place has
    /// nothing to keep.
    public mutating func setMinimized(_ id: Int, _ minimized: Bool) {
        guard places[id] != nil, (places[id]?.minimized == true) != minimized else { return }
        places[id]?.minimized = minimized ? true : nil
    }

    public mutating func remove(_ id: Int) { places[id] = nil }

    /// Keeps only the places of these windows: the computer's complete set, once it has
    /// announced them after connecting.
    public mutating func prune(keeping live: Set<Int>) {
        places = places.filter { live.contains($0.key) }
    }

    private mutating func trim() {
        guard places.count > Self.capacity else { return }
        let oldest = places.sorted { $0.value.touched < $1.value.touched }.prefix(places.count - Self.capacity)
        for (id, _) in oldest { places[id] = nil }
    }

    // MARK: Geometry

    /// A snap's frame in the work area. A window too large for a half or a corner takes
    /// what it needs from the opposite side rather than spilling off the desktop.
    public static func rect(for snap: Snap, in area: CGRect, minimum: CGSize = .zero) -> CGRect {
        let halfWidth = (area.width / 2).rounded(.down), halfHeight = (area.height / 2).rounded(.down)
        let width = min(area.width, max(halfWidth, minimum.width))
        let height = min(area.height, max(halfHeight, minimum.height))
        switch snap {
        case .maximized: return area
        case .left: return CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
        case .right: return CGRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
        case .topLeft: return CGRect(x: area.minX, y: area.minY, width: width, height: height)
        case .topRight: return CGRect(x: area.maxX - width, y: area.minY, width: width, height: height)
        case .bottomLeft: return CGRect(x: area.minX, y: area.maxY - height, width: width, height: height)
        case .bottomRight: return CGRect(x: area.maxX - width, y: area.maxY - height, width: width, height: height)
        }
    }

    /// Whether a window of this minimum size can take the snap without covering more than
    /// the snap asks for.
    public static func allows(_ snap: Snap, in area: CGRect, minimum: CGSize) -> Bool {
        let half = CGSize(width: area.width / 2, height: area.height / 2)
        switch snap {
        case .maximized: return true
        case .left, .right: return minimum.width <= half.width
        default: return minimum.width <= half.width && minimum.height <= half.height
        }
    }

    /// The snap a title bar dragged to `point` would take: a side edge snaps to that half,
    /// near a corner to that quarter (where quarters are at least `minimumQuarter`), the top
    /// edge maximizes. `edge` is how near counts, in points.
    public static func zone(at point: CGPoint, in area: CGRect, edge: CGFloat,
                            minimumQuarter: CGSize = CGSize(width: 280, height: 200)) -> Snap? {
        let quarters = area.width / 2 >= minimumQuarter.width && area.height / 2 >= minimumQuarter.height
        let corner = max(edge * 3, area.height / 5)
        let left = point.x <= area.minX + edge, right = point.x >= area.maxX - edge
        if left || right {
            if quarters, point.y <= area.minY + corner { return left ? .topLeft : .topRight }
            if quarters, point.y >= area.maxY - corner { return left ? .bottomLeft : .bottomRight }
            return left ? .left : .right
        }
        if point.y <= area.minY + edge { return .maximized }
        return nil
    }

    /// `frame` from the work area `old` in the work area `new`: the same size where it fits,
    /// otherwise shrunk to fit (never below `minimum`), with the free space on either side
    /// shared in the same proportion. A window against an edge stays against it, and a
    /// centred one stays centred.
    public static func refit(_ frame: CGRect, from old: CGRect, to new: CGRect, minimum: CGSize = .zero) -> CGRect {
        let width = min(frame.width, max(new.width, 1)).rounded()
        let height = min(frame.height, max(new.height, 1)).rounded()
        let size = CGSize(width: max(width, min(minimum.width, new.width)), height: max(height, min(minimum.height, new.height)))
        func share(_ offset: CGFloat, _ oldSpace: CGFloat, _ newSpace: CGFloat) -> CGFloat {
            guard newSpace > 0 else { return 0 }
            guard oldSpace > 0 else { return min(max(0, offset), newSpace) }
            return (min(max(0, offset), oldSpace) / oldSpace * newSpace).rounded()
        }
        let x = new.minX + share(frame.minX - old.minX, old.width - frame.width, new.width - size.width)
        let y = new.minY + share(frame.minY - old.minY, old.height - frame.height, new.height - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// A frame kept wholly inside the work area, as large as it fits.
    public static func clamped(_ frame: CGRect, to area: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, area.width), height: min(frame.height, area.height))
        return CGRect(x: min(max(area.minX, frame.minX), area.maxX - size.width),
                      y: min(max(area.minY, frame.minY), area.maxY - size.height),
                      width: size.width, height: size.height)
    }

    /// The frame a snapped window takes back when its title bar is dragged out of the snap:
    /// its preferred size, under the finger at the same place across the title bar.
    public static func unsnapped(size: CGSize, from snapped: CGRect, grab: CGPoint, in area: CGRect) -> CGRect {
        let fraction = snapped.width > 0 ? (grab.x - snapped.minX) / snapped.width : 0.5
        let frame = CGRect(x: grab.x - size.width * min(max(0, fraction), 1), y: snapped.minY,
                           width: size.width, height: size.height)
        return clamped(frame, to: area)
    }

    /// Pulls a moving frame's edges onto nearby edges, within `threshold` points: the work
    /// area's edges, and the edges of every window it nearly touches, so it meets them side
    /// to side or lines up with them.
    public static func magnetized(_ frame: CGRect, others: [CGRect], in area: CGRect, threshold: CGFloat) -> CGRect {
        func pull(_ low: CGFloat, _ high: CGFloat, targets: [CGFloat]) -> CGFloat {
            var best: CGFloat = 0, distance = threshold + 1
            for target in targets {
                for edge in [low, high] where abs(target - edge) < distance {
                    distance = abs(target - edge)
                    best = target - edge
                }
            }
            return distance <= threshold ? best : 0
        }
        var xs = [area.minX, area.maxX], ys = [area.minY, area.maxY]
        for other in others where frame.insetBy(dx: -threshold, dy: -threshold).intersects(other) {
            xs += [other.minX, other.maxX]
            ys += [other.minY, other.maxY]
        }
        return frame.offsetBy(dx: pull(frame.minX, frame.maxX, targets: xs), dy: pull(frame.minY, frame.maxY, targets: ys))
    }

    /// The window nearest `from` in a direction, by the centres of their frames: among those
    /// lying more that way than across it, the closest along it, with distance across
    /// counting double, so a window straight ahead wins over a nearer one far to the side.
    /// Nil when nothing lies that way.
    public static func neighbour(_ direction: YardLayout.Direction, from: CGRect, among frames: [Int: CGRect]) -> Int? {
        let origin = CGPoint(x: from.midX, y: from.midY)
        var best: (id: Int, score: CGFloat)?
        for (id, frame) in frames.sorted(by: { $0.key < $1.key }) {
            let dx = frame.midX - origin.x, dy = frame.midY - origin.y
            let along: CGFloat, across: CGFloat
            switch direction {
            case .left: (along, across) = (-dx, dy)
            case .right: (along, across) = (dx, dy)
            case .up: (along, across) = (-dy, dx)
            case .down: (along, across) = (dy, dx)
            }
            guard along > 1, along * 2 >= abs(across) else { continue }
            let score = along + 2 * abs(across)
            if best == nil || score < best!.score { best = (id, score) }
        }
        return best?.id
    }

    // MARK: Saving

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decoded(from data: Data?) -> FreeDesktopLayout {
        data.flatMap { try? JSONDecoder().decode(FreeDesktopLayout.self, from: $0) } ?? FreeDesktopLayout()
    }
}
