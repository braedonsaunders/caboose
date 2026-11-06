import Foundation

/// The screen the computer lays windows out for: the phone's, or a connected display's.
/// It becomes the display described in the Caboose Display `hello` (`DisplayInfo`).
public struct ClientCapabilities: Codable, Equatable, Sendable {
    public var desktopWidth: Int
    public var desktopHeight: Int
    /// Linux text follows this: 96 is scale 1, 192 is scale 2.
    public var dpi: Int
    public var refreshRate: Int

    public init(desktopWidth: Int, desktopHeight: Int, dpi: Int, refreshRate: Int = 60) {
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.dpi = dpi
        self.refreshRate = refreshRate
    }

    /// The agent seat's screen, the same from every phone and in every orientation: the agent
    /// lays its windows out for it and the phone only watches, so connecting must not change
    /// the seat's size or density under the agent. It is caboose-display's own display before a
    /// client connects (`--display`, 1920x1080 at 60 Hz, scale 1).
    public static let agentSeat = ClientCapabilities(desktopWidth: 1920, desktopHeight: 1080, dpi: 96, refreshRate: 60)
}
