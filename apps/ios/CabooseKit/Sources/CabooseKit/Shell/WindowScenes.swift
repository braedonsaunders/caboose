import CoreGraphics
import Foundation

/// One Linux window shown in an iPadOS window of its own: the paired computer, the server
/// lifetime (`epoch`) and the window id. Window ids name the same window only within one
/// epoch, so a reference is never made without one.
///
/// Equality and hashing use the computer, epoch and window alone, so opening the same window
/// twice brings its window forward. The title and app name travel with it, so a window
/// restored after its Linux window has gone can still say what it showed.
public struct LinuxWindowRef: Codable, Hashable, Sendable {
    /// The paired computer's local identity (its Files domain identifier).
    public let computer: String
    public let epoch: String
    public let window: Int
    public var title: String
    public var app: String

    public init?(computer: String?, epoch: String?, window: Int, title: String = "", app: String = "") {
        guard let computer, !computer.isEmpty, let epoch, !epoch.isEmpty else { return nil }
        self.computer = computer
        self.epoch = epoch
        self.window = window
        self.title = title
        self.app = app
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.computer == b.computer && a.epoch == b.epoch && a.window == b.window
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(computer)
        hasher.combine(epoch)
        hasher.combine(window)
    }

    /// What to call it: its last title, else its app's name.
    public var name: String {
        if !title.isEmpty { return title }
        return app.isEmpty ? "Window" : app
    }

    /// Whether this names window `id` of `computer` in the server lifetime `epoch`.
    public func names(window id: Int, computer: String?, epoch: String?) -> Bool {
        id == window && computer == self.computer && epoch == self.epoch
    }

    public enum Presence: Equatable, Sendable {
        /// The computer is not connected, or has not announced its windows yet.
        case waiting
        /// The window is in the display session.
        case present
        /// The window closed, or the computer's display started again since (another epoch).
        case gone
        /// Another computer is paired now, or none is.
        case otherComputer
    }

    /// Where the window stands in the display session now. `ready` is a connected session
    /// that has said hello; `announced` is true once that session has announced every
    /// window the server has; `windowExists` is whether the session has this window id as an
    /// application window. A window kept through a lost connection is still present.
    public func presence(computer: String?, epoch: String?, ready: Bool, announced: Bool, windowExists: Bool) -> Presence {
        guard computer == self.computer else { return .otherComputer }
        if windowExists, epoch == self.epoch { return .present }
        guard ready else { return .waiting }
        // A server lifetime other than the window's, or one that names none, has lost it.
        guard let epoch, epoch == self.epoch else { return .gone }
        return announced ? .gone : .waiting
    }

    // MARK: Dragging a window out

    /// The `NSUserActivity` type that carries a window dragged out of the app, so iPadOS
    /// opens it in a window of its own where it is dropped.
    public static let activityType = "com.braedonsaunders.caboose.linux-window"
    private static let activityKey = "window"

    /// The activity's `userInfo`: the reference, encoded.
    public var activityUserInfo: [String: Any] {
        guard let data = try? JSONEncoder().encode(self) else { return [:] }
        return [Self.activityKey: data]
    }

    public init?(activityUserInfo: [AnyHashable: Any]?) {
        guard let data = activityUserInfo?[Self.activityKey] as? Data,
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              let valid = Self(computer: decoded.computer, epoch: decoded.epoch, window: decoded.window,
                               title: decoded.title, app: decoded.app) else { return nil }
        self = valid
    }
}

/// The Linux windows shown in iPadOS windows of their own, by the scene showing each. A scene
/// shows one window, and a window is shown by one scene. A window held by a scene is laid out
/// by that scene alone: the in-app desktop, its tiles and app cards leave it, and the menus
/// and dialogs that belong to it, to the scene.
public struct DetachedWindows: Equatable, Sendable {
    /// Each scene's window, by the scene's persistent identifier.
    public private(set) var claims: [String: LinuxWindowRef] = [:]

    public init() {}

    /// Scene `scene` shows `ref`. When another scene already shows it, that scene keeps it and
    /// is returned; nothing changes.
    @discardableResult
    public mutating func claim(_ ref: LinuxWindowRef, scene: String) -> String? {
        if let other = claims.first(where: { $0.key != scene && $0.value == ref })?.key { return other }
        claims[scene] = ref
        return nil
    }

    /// Scene `scene` closed or stopped showing a window: its window goes back to the desktop.
    public mutating func release(scene: String) {
        claims.removeValue(forKey: scene)
    }

    /// The scene showing window `id` of `computer` in the server lifetime `epoch`, if any.
    public func scene(showing id: Int, computer: String?, epoch: String?) -> String? {
        claims.filter { $0.value.names(window: id, computer: computer, epoch: epoch) }.keys.min()
    }

    /// The window ids scenes show for `computer` in the server lifetime `epoch`.
    public func windows(computer: String?, epoch: String?) -> Set<Int> {
        Set(claims.values.filter { $0.computer == computer && $0.epoch == epoch }.map(\.window))
    }

    /// `held` and every window whose chain of transient parents (`parents`, each window's
    /// parent id) leads to one of them: its menus, popups and dialogs. A popup without a
    /// parent belongs to no window and is not included.
    public static func withDescendants(_ held: Set<Int>, parents: [Int: Int]) -> Set<Int> {
        guard !held.isEmpty else { return [] }
        var result = held
        for id in parents.keys where !held.contains(id) {
            var seen: Set<Int> = [id]
            var next = parents[id]
            while let ancestor = next, seen.insert(ancestor).inserted {
                if held.contains(ancestor) {
                    result.insert(id)
                    break
                }
                next = parents[ancestor]
            }
        }
        return result
    }
}

/// The sizes an iPadOS window showing a Linux window may take, from the Linux window's own
/// limits, in points.
public struct SceneSizeLimits: Equatable, Sendable {
    public static let unbounded = CGFloat.greatestFiniteMagnitude

    public var minimum: CGSize
    public var maximum: CGSize

    public init(minimum: CGSize, maximum: CGSize) {
        self.minimum = minimum
        self.maximum = maximum
    }

    /// `minimum` and `maximum` are the window's size hints in display pixels, where a side of
    /// zero (or a missing hint) is no limit. `chrome` is the room the iPadOS window takes
    /// around the Linux window (its bar and safe areas), added to every limit. The maximum is
    /// never below the minimum.
    public static func limits(minimum: CGSize?, maximum: CGSize?, pixelsPerPoint: CGFloat, chrome: CGSize) -> SceneSizeLimits {
        guard pixelsPerPoint > 0 else {
            return SceneSizeLimits(minimum: .zero, maximum: CGSize(width: unbounded, height: unbounded))
        }
        func lower(_ pixels: CGFloat?, _ extra: CGFloat) -> CGFloat {
            guard let pixels, pixels > 0, pixels.isFinite else { return 0 }
            return (pixels / pixelsPerPoint).rounded(.up) + max(0, extra)
        }
        func upper(_ pixels: CGFloat?, _ extra: CGFloat, atLeast floor: CGFloat) -> CGFloat {
            guard let pixels, pixels > 0, pixels.isFinite else { return unbounded }
            return max(floor, (pixels / pixelsPerPoint).rounded(.down) + max(0, extra))
        }
        let low = CGSize(width: lower(minimum?.width, chrome.width), height: lower(minimum?.height, chrome.height))
        let high = CGSize(width: upper(maximum?.width, chrome.width, atLeast: low.width),
                          height: upper(maximum?.height, chrome.height, atLeast: low.height))
        return SceneSizeLimits(minimum: low, maximum: high)
    }
}
