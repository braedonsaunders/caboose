import CoreGraphics

/// The title bar above a Linux window on the desktop and in a Switchyard tile: the
/// window's controls at its leading edge, as on a Mac, then its title.
///
/// The controls are drawn small, as a Mac's are, and each answers across a slice of the bar
/// as tall as the bar and as wide as the space between neighbours, the first running to the
/// bar's leading edge, so a finger can find them. Drawing and hit-testing both come from
/// here, so what is seen is what answers.
public struct WindowTitleBar: Equatable, Sendable {
    public enum Control: Sendable, CaseIterable {
        case close, minimize, zoom
    }

    public let controls: [Control]
    /// The bar's height, in points.
    public let height: CGFloat
    /// Each control's circle.
    public let diameter: CGFloat
    /// From one control's centre to the next.
    public let pitch: CGFloat
    /// From the leading edge to the first control's centre.
    public let leading: CGFloat

    /// `ui` scales the bar for the distance it is seen from. Under a finger it never
    /// shrinks below a Mac's size, and its controls sit further apart.
    public init(ui: CGFloat = 1, touch: Bool, controls: [Control] = Control.allCases) {
        let scale = touch ? max(1, ui) : ui
        self.controls = controls
        height = (touch ? 32 : 30) * scale
        diameter = 12 * scale
        pitch = (touch ? 28 : 20) * scale
        leading = (touch ? 20 : 18) * scale
    }

    /// The x of a control's centre, from the bar's leading edge.
    public func centre(of control: Control) -> CGFloat? {
        controls.firstIndex(of: control).map { leading + CGFloat($0) * pitch }
    }

    /// Where a control answers, in the bar's own coordinates.
    public func hitFrame(of control: Control) -> CGRect? {
        guard let index = controls.firstIndex(of: control), let centre = centre(of: control) else { return nil }
        let minX = index == 0 ? 0 : centre - pitch / 2
        return CGRect(x: minX, y: 0, width: centre + pitch / 2 - minX, height: height)
    }

    /// The control at a point in the bar's own coordinates, if any.
    public func control(at point: CGPoint) -> Control? {
        guard point.y >= 0, point.y < height else { return nil }
        return controls.first { hitFrame(of: $0)?.contains(point) == true }
    }

    /// Where the controls end and the title may begin.
    public var controlsWidth: CGFloat {
        controls.isEmpty ? 0 : leading + CGFloat(controls.count - 1) * pitch + pitch / 2
    }
}
