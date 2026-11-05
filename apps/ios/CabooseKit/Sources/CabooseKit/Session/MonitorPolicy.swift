import CoreGraphics
import Foundation

/// The device's selected output and presentation pixel density, local to one computer.
/// Home can connect without choosing either; only a real presentation attaches a mode.
public struct MonitorPolicy {
    public struct Selection: Codable, Equatable, Sendable {
        public let capabilities: ClientCapabilities
        public let renderScale: Double

        public init?(capabilities: ClientCapabilities, renderScale: Double) {
            guard Self.valid(capabilities, renderScale) else { return nil }
            self.capabilities = capabilities
            self.renderScale = renderScale
        }

        private static func valid(_ c: ClientCapabilities, _ scale: Double) -> Bool {
            // Persistence is untrusted. Bound arithmetic and protocol dimensions; these
            // are validation limits, not a minimum desktop resolution or a chosen DPI.
            (1...32768).contains(c.desktopWidth) && (1...32768).contains(c.desktopHeight)
                && (1...960).contains(c.dpi) && (1...1000).contains(c.refreshRate)
                && scale.isFinite && (0.25...8).contains(scale)
        }

        fileprivate var isValid: Bool { Self.valid(capabilities, renderScale) }
    }

    private struct Saved: Codable {
        let version: Int
        let computer: String
        let selection: Selection
    }

    public private(set) var computer: String?
    public private(set) var selection: Selection?
    public private(set) var physicalScreen: CGSize?
    public private(set) var laptopPanel: CGSize?
    public var device: ClientCapabilities? { selection?.capabilities }
    public init() {}

    /// Call before start/resume and before attaching a presentation. A different
    /// computer never inherits this computer's output, including malformed saved data.
    public mutating func bind(computer: String?, saved: Data?) {
        guard self.computer != computer else { return }
        self.computer = computer
        selection = nil
        physicalScreen = nil
        laptopPanel = nil
        guard let computer, !computer.isEmpty, let saved, saved.count <= 4096,
              let record = try? JSONDecoder().decode(Saved.self, from: saved),
              record.version == 1, record.computer == computer, record.selection.isValid else { return }
        selection = record.selection
    }

    public func saved() -> Data? {
        guard let computer, !computer.isEmpty, let selection else { return nil }
        return try? JSONEncoder().encode(Saved(version: 1, computer: computer, selection: selection))
    }

    /// Selection is explicit, unlike resolving Home's capabilities. Repeated layout
    /// callbacks and later cards do not replace a desktop's chosen DPI or render scale.
    @discardableResult public mutating func attach(_ candidate: Selection) -> Bool {
        guard computer != nil, selection == nil, candidate.isValid else { return false }
        selection = candidate
        return true
    }

    public func resolve(external: ClientCapabilities? = nil) -> ClientCapabilities? {
        if let external { return external }
        guard var device, let panel = laptopPanel ?? physicalScreen, let selection else { return device }
        guard let width = Self.pixels(Double(panel.width), scale: selection.renderScale),
              let height = Self.pixels(Double(panel.height), scale: selection.renderScale),
              width <= 32768, height <= 32768 else { return device }
        device.desktopWidth = width
        device.desktopHeight = height
        return device
    }

    /// A scene-window measurement and its optional upper panel are one physical
    /// transition. Neither keyboard avoidance nor a card's proposed size belongs here.
    /// Saved density remains authoritative, including for older square saved modes.
    @discardableResult public mutating func presentDevice(screen: CGSize, laptopPanel: CGSize?) -> Bool {
        guard computer != nil, Self.validPhysicalSize(screen),
              laptopPanel.map(Self.validPhysicalSize) ?? true else { return false }
        guard physicalScreen != screen || self.laptopPanel != laptopPanel else { return false }
        physicalScreen = screen
        self.laptopPanel = laptopPanel
        return true
    }

    private static func validPhysicalSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width <= 32768 && size.height <= 32768
    }

    /// Only the attached physical Laptop panel supplies this transient mode. Keyboard,
    /// cards and ordinary viewport layout never feed it. The saved selection is untouched.
    @discardableResult public mutating func presentLaptop(panel: CGSize?) -> Bool {
        if let panel {
            guard computer != nil, Self.validPhysicalSize(panel) else { return false }
        }
        guard laptopPanel != panel else { return false }
        laptopPanel = panel
        return true
    }

    public static func fullDevice(screen: CGSize, pixelsPerPoint: CGFloat, dpi: Int,
                                  refreshRate: Int) -> ClientCapabilities {
        return ClientCapabilities(desktopWidth: pixels(Double(screen.width), scale: Double(pixelsPerPoint)) ?? 0,
                                  desktopHeight: pixels(Double(screen.height), scale: Double(pixelsPerPoint)) ?? 0,
                                  dpi: dpi, refreshRate: refreshRate)
    }

    /// The whole computer pixels that cover `points` at `scale`: rounded up, so a display made
    /// for a panel of fractional pixels reaches its edge (the phone clips the part past it)
    /// instead of ending short of it. A value within a thousandth of a pixel of a whole one
    /// is that one. Nil for no pixels.
    public static func pixels(_ points: Double, scale: Double) -> Int? {
        let value = points * scale
        guard value.isFinite, value >= 0.001, value <= 1_048_576 else { return nil }
        let nearest = value.rounded()
        return Int(abs(value - nearest) < 0.001 ? nearest : value.rounded(.up))
    }

    /// Only an explicit owner zoom changes the retained device DPI.
    public mutating func zoomDevice(by factor: Double) {
        guard factor.isFinite, factor > 0, let selected = selection else { return }
        var value = selected.capabilities
        let dpi = (Double(value.dpi) * factor).rounded()
        guard dpi.isFinite, dpi >= 1, dpi <= 960 else { return }
        value.dpi = Int(dpi)
        selection = Selection(capabilities: value, renderScale: selected.renderScale)
    }
}
