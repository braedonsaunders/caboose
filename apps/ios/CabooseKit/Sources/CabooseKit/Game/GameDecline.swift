import Foundation

/// The client giving a game back to the computer (`game.decline`, docs/game-handoff.md,
/// "Declining"): when the page cannot run on this device, the computer runs the game instead.
public enum GameDecline {
    /// The most UTF-8 bytes a reason takes on the wire.
    public static let reasonLimit = 200

    /// `reason` cut to `reasonLimit` UTF-8 bytes, at a character boundary.
    public static func bounded(_ reason: String) -> String {
        guard reason.utf8.count > reasonLimit else { return reason }
        var count = 0
        var end = reason.startIndex
        for index in reason.indices {
            let next = reason.index(after: index)
            count += reason[index ..< next].utf8.count
            guard count <= reasonLimit else { break }
            end = next
        }
        return String(reason[..<end])
    }

    /// The page stopped on an error while it was not cross-origin isolated.
    static func notIsolated(_ message: String) -> String {
        message.isEmpty ? "the page is not cross-origin isolated" : "the page is not cross-origin isolated and stopped: \(message)"
    }

    static let terminatedTwice = "WebKit ended the page twice within a minute"

    static func notServed(_ error: Error) -> String {
        "the device could not serve the game's files: \(error.localizedDescription)"
    }
}

/// When WebKit ended a game's page: the first time the page starts again, a second within
/// `window` of it means the device cannot run the game.
struct GameTerminations {
    static let window: TimeInterval = 60
    private var last: Date?

    /// Records an ending at `now`; true when it is the second within `window`.
    mutating func record(_ now: Date) -> Bool {
        defer { last = now }
        guard let last else { return false }
        return now.timeIntervalSince(last) <= Self.window
    }
}
