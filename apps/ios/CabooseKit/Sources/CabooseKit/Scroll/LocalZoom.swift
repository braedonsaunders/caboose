import CoreGraphics
import Foundation

/// A pinch the phone composes itself, as UIScrollView zooms: the window's picture scales with
/// the fingers at display rate, rubber-banding past the scales the page allows, and on lift
/// settles within them with the viewport covered. The app is then asked to zoom to where the
/// fingers left the content, and the composition holds until its picture at that scale arrives.
///
/// Scales are relative to the app's scale when the pinch began; points are viewport pixels.
public struct LocalZoom: Sendable {
    public enum Phase: Sendable { case pinching, settling, waiting }
    public private(set) var phase: Phase = .pinching
    /// Viewport point `p` shows at `p * zoom + translation`.
    public private(set) var zoom: Double = 1
    public private(set) var translation: CGPoint = .zero
    public let limits: ClosedRange<Double>
    /// The viewport the pinch scales, once its picture is known.
    public var viewport: CGSize
    private let start: CGPoint
    private var centroid: CGPoint
    private var settle: (zoom: Double, translation: CGPoint, toZoom: Double, toTranslation: CGPoint, at: TimeInterval)?
    /// When the settled zoom was handed to the app.
    public private(set) var waitingSince: TimeInterval?

    static let settleDuration: TimeInterval = 0.3
    /// How much of a pinch past a limit shows, as an exponent of the excess scale.
    static let rubberBand = 0.3

    public init(centroid: CGPoint, viewport: CGSize, limits: ClosedRange<Double>) {
        start = centroid
        self.centroid = centroid
        self.viewport = viewport
        self.limits = limits
    }

    /// The fingers' cumulative scale and their centroid now.
    public mutating func pinch(scale: Double, centroid: CGPoint) {
        guard phase == .pinching, scale > 0 else { return }
        var z = scale
        if z > limits.upperBound { z = limits.upperBound * pow(z / limits.upperBound, Self.rubberBand) }
        if z < limits.lowerBound { z = limits.lowerBound * pow(z / limits.lowerBound, Self.rubberBand) }
        zoom = z
        // The content that was under the fingers stays under them.
        translation = CGPoint(x: centroid.x - start.x * z, y: centroid.y - start.y * z)
        self.centroid = centroid
    }

    /// The fingers lifted: where the zoom settles, within the limits about the fingers'
    /// centroid, with no edge of the content pulled inside the viewport.
    public mutating func end(at time: TimeInterval) -> (zoom: Double, translation: CGPoint) {
        let z = min(max(zoom, limits.lowerBound), limits.upperBound)
        let pinned = CGPoint(x: (centroid.x - translation.x) / zoom, y: (centroid.y - translation.y) / zoom)
        var t = CGPoint(x: centroid.x - pinned.x * z, y: centroid.y - pinned.y * z)
        func cover(_ value: CGFloat, _ extent: CGFloat) -> CGFloat {
            z >= 1 ? min(0, max(extent * (1 - z), value)) : extent * (1 - z) / 2
        }
        t = CGPoint(x: cover(t.x, viewport.width), y: cover(t.y, viewport.height))
        settle = (zoom, translation, z, t, time)
        phase = .settling
        return (z, t)
    }

    /// Back to the app's own scale, as when the app cannot zoom.
    public mutating func cancel(at time: TimeInterval) {
        settle = (zoom, translation, 1, .zero, time)
        phase = .settling
    }

    /// Advances the settling animation (UIScrollView's ease-out).
    public mutating func tick(at time: TimeInterval) {
        guard phase == .settling, let s = settle else { return }
        let progress = min(1, max(0, (time - s.at) / Self.settleDuration))
        let eased = 1 - pow(1 - progress, 3)
        zoom = s.zoom * pow(s.toZoom / s.zoom, eased)
        translation = CGPoint(x: s.translation.x + (s.toTranslation.x - s.translation.x) * eased,
                              y: s.translation.y + (s.toTranslation.y - s.translation.y) * eased)
        if progress >= 1 {
            zoom = s.toZoom
            translation = s.toTranslation
            phase = .waiting
            waitingSince = time
        }
    }

    /// The point a pure scale to `zoom` keeps still, which reproduces `translation`: what the
    /// app zooms about. Nil when the scale is unchanged.
    public static func focus(zoom: Double, translation: CGPoint) -> CGPoint? {
        guard abs(1 - zoom) > 1e-3 else { return nil }
        return CGPoint(x: translation.x / (1 - zoom), y: translation.y / (1 - zoom))
    }
}
