import Foundation

/// The apps Home shows first: the ones the owner pinned, in the order they pinned them, and
/// the ones they opened most recently. Both are desktop-entry ids kept on the phone for one
/// computer; ids the computer no longer has are skipped, not forgotten, so an app that comes
/// back after a reinstall keeps its place.
public struct AppShortcuts: Codable, Equatable, Sendable {
    public private(set) var pinned: [String]
    public private(set) var recent: [String]

    /// How many recently opened apps are remembered.
    public static let recentLimit = 12

    public init(pinned: [String] = [], recent: [String] = []) {
        self.pinned = pinned
        self.recent = recent
    }

    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    /// Pins an app at the end of the pinned row, or unpins it.
    public mutating func togglePin(_ id: String) {
        if let index = pinned.firstIndex(of: id) { pinned.remove(at: index) } else { pinned.append(id) }
    }

    /// Moves an opened app to the front of the recent list.
    public mutating func recordOpen(_ id: String) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }

    /// Pinned apps the computer has, in pinned order.
    public func pinnedApps(available: Set<String>) -> [String] {
        pinned.filter(available.contains)
    }

    /// Recently opened apps the computer has, newest first, without the pinned ones.
    public func recentApps(available: Set<String>, limit: Int) -> [String] {
        Array(recent.filter { available.contains($0) && !pinned.contains($0) }.prefix(limit))
    }
}
