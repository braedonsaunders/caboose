import CoreGraphics
import Foundation

/// What Switchyard keeps between launches for one computer: the track itself, and the width
/// each app was last given by hand, so it opens at that width next time.
///
/// Window ids survive reconnects and parking, so a saved layout lays the same windows out
/// again; windows that have since closed are pruned when the computer's windows arrive. Apps
/// are keyed by their window class, which is stable where window ids are not (a restart).
/// A new display server lifetime numbers its windows afresh, so its first windows find an
/// empty track rather than another lifetime's columns (`enter(epoch:)`).
public struct YardMemory: Codable, Equatable, Sendable {
    public var layout = YardLayout()
    /// Hand-chosen widths by app class, as fractions of the screen.
    public private(set) var widths: [String: CGFloat] = [:]
    /// The display server lifetime the layout's window ids belong to, when it reports one.
    public private(set) var epoch: String?

    public init() {}

    /// Clears the track for a new display server lifetime, or for the first one reported
    /// (nothing proves which lifetime an older track's ids belong to), keeping the
    /// hand-chosen widths, which belong to apps rather than windows. A server that reports
    /// no epoch, or the same one again, changes nothing.
    public mutating func enter(epoch: String?) {
        guard let epoch, epoch != self.epoch else { return }
        layout = YardLayout()
        self.epoch = epoch
    }

    /// The width a new window of `appClass` opens at, if it was ever chosen by hand.
    public func width(for appClass: String?) -> CGFloat? {
        appClass.flatMap { widths[$0.lowercased()] }
    }

    /// Records the hand-chosen widths of the columns that hold a single window, so a stack's
    /// width is not taken for any one of its apps.
    public mutating func learnWidths(appClass: (Int) -> String?) {
        for column in layout.columns where column.pinned && column.windows.count == 1 {
            if let name = appClass(column.windows[0])?.lowercased(), !name.isEmpty { widths[name] = column.width }
        }
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decoded(from data: Data?) -> YardMemory {
        data.flatMap { try? JSONDecoder().decode(YardMemory.self, from: $0) } ?? YardMemory()
    }
}
