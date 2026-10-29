import CoreGraphics
import Foundation

/// A virtual monitor outlives the phone viewport presenting its windows. The first
/// device attachment retains the caller's full-screen dimensions and chosen DPI;
/// cards, keyboard and desktop stage measurements cannot replace that selection.
public struct MonitorPolicy {
    public private(set) var device: ClientCapabilities?

    public init() {}

    /// The existing full-device square fits either orientation. The caller supplies
    /// the chosen DPI independently of render pixels per point; do not derive it
    /// again from a reduced viewport or normalize a desktop's UI scale to the phone's.
    public static func fullDevice(screen: CGSize, pixelsPerPoint: CGFloat, dpi: Int,
                                  refreshRate: Int) -> ClientCapabilities {
        let side = max(screen.width, screen.height)
        return ClientCapabilities(desktopWidth: Int(side * pixelsPerPoint),
                                  desktopHeight: Int(side * pixelsPerPoint),
                                  dpi: dpi, refreshRate: refreshRate)
    }

    /// External monitors retain their own mode and DPI. Attaching one first does not
    /// preselect the device monitor, and detaching returns to the retained selection.
    public mutating func resolve(device candidate: ClientCapabilities,
                                 external: ClientCapabilities? = nil) -> ClientCapabilities {
        if let external { return external }
        if device == nil { device = candidate }
        return device!
    }

    /// Only an explicit owner zoom changes an attached device monitor's DPI.
    public mutating func zoomDevice(by factor: Double) {
        guard factor.isFinite, factor > 0, var value = device else { return }
        let dpi = (Double(value.dpi) * factor).rounded()
        guard dpi.isFinite, dpi >= 1, dpi < Double(Int.max) else { return }
        value.dpi = Int(dpi)
        device = value
    }
}
