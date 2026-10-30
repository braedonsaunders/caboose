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
}
