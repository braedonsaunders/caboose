import CoreGraphics

/// Ordinary window requests in guest pixels. Minimum/maximum hints are per axis;
/// zero, negative and non-finite values mean no constraint. An inconsistent maximum
/// never overrides a minimum. Fullscreen geometry belongs to the compositor.
public enum WindowSizePolicy {
    /// A layout-owned viewport (tile, card or snap) retains its aspect when an app
    /// requires more pixels. Grow both axes together rather than producing a wide,
    /// short picture that must then be letterboxed inside a tall viewport. Genuine
    /// fixed sizes and conflicting aspect constraints retain the per-axis fallback.
    public static func fitting(_ viewport: CGRect, minimum: CGSize?, maximum: CGSize?,
                               fullscreen: Bool) -> CGRect? {
        guard let fallback = request(viewport, minimum: minimum, maximum: maximum,
                                     fullscreen: fullscreen) else { return nil }
        let (smallest, largest) = factors(viewport.size, minimum: minimum, maximum: maximum)
        guard smallest.isFinite, smallest <= largest else { return fallback }
        let factor = min(largest, max(smallest, 1))
        let size = CGSize(width: viewport.width * factor, height: viewport.height * factor)
        guard size.width.isFinite, size.height.isFinite else { return fallback }
        return request(CGRect(origin: viewport.origin, size: size), minimum: minimum,
                       maximum: maximum, fullscreen: false)
    }

    /// Whether a window can fill `viewport` as `fitting` lays it out: at the viewport's own
    /// size, or, held larger by its minimum size, at the viewport's shape grown to that
    /// minimum and shown scaled down. A window whose maximum keeps it smaller than the
    /// viewport, or from the viewport's shape, cannot.
    public static func fills(_ viewport: CGSize, minimum: CGSize?, maximum: CGSize?) -> Bool {
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else { return false }
        let (smallest, largest) = factors(viewport, minimum: minimum, maximum: maximum)
        return smallest.isFinite && max(1, smallest) <= largest
    }

    /// How far the viewport must grow (`smallest`, for the minimum) and may grow (`largest`,
    /// for the maximum) at its own shape.
    private static func factors(_ viewport: CGSize, minimum: CGSize?, maximum: CGSize?) -> (smallest: CGFloat, largest: CGFloat) {
        func lower(_ value: CGFloat?) -> CGFloat {
            value.flatMap { $0.isFinite && $0 > 0 ? max(1, $0.rounded(.up)) : nil } ?? 1
        }
        func upper(_ value: CGFloat?, lower: CGFloat) -> CGFloat {
            value.flatMap { $0.isFinite && $0 > 0 ? max(lower, $0.rounded(.down)) : nil } ?? .infinity
        }
        let minWidth = lower(minimum?.width), minHeight = lower(minimum?.height)
        let maxWidth = upper(maximum?.width, lower: minWidth)
        let maxHeight = upper(maximum?.height, lower: minHeight)
        return (max(minWidth / viewport.width, minHeight / viewport.height),
                min(maxWidth / viewport.width, maxHeight / viewport.height))
    }

    /// A window that cannot grow to fill `area` (a fixed-size starter window, a capped
    /// dialog) sits in its middle, as a tile shows it; one that must be larger keeps the
    /// area's leading and top edges.
    public static func centred(_ fitted: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: (area.minX + max(0, area.width - fitted.width) / 2).rounded(),
               y: (area.minY + max(0, area.height - fitted.height) / 2).rounded(),
               width: fitted.width, height: fitted.height)
    }

    public static func request(_ proposed: CGRect, minimum: CGSize?, maximum: CGSize?,
                               fullscreen: Bool) -> CGRect? {
        guard !fullscreen, proposed.minX.isFinite, proposed.minY.isFinite,
              proposed.width.isFinite, proposed.height.isFinite,
              proposed.width > 0, proposed.height > 0 else { return nil }

        func dimension(_ desired: CGFloat, _ lower: CGFloat?, _ upper: CGFloat?) -> CGFloat {
            let minValue = lower.flatMap { $0.isFinite && $0 > 0 ? max(1, $0.rounded(.up)) : nil } ?? 1
            let maxValue = upper.flatMap { $0.isFinite && $0 > 0 ? max(minValue, $0.rounded(.down)) : nil }
            let value = max(minValue, desired.rounded(.up))
            return maxValue.map { min(value, $0) } ?? value
        }
        return CGRect(x: proposed.minX.rounded(), y: proposed.minY.rounded(),
                      width: dimension(proposed.width, minimum?.width, maximum?.width),
                      height: dimension(proposed.height, minimum?.height, maximum?.height))
    }
}
