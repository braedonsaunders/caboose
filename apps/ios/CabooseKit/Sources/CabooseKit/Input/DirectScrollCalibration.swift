import Foundation

/// Converts mapped direct-content distance to the existing precise pointer units.
/// Xwayland exposes one XI2 scroll increment per 10 Wayland axis units; the
/// Chromium reference consumes 120 content units per increment. This is a
/// reference gain, not a promise about every toolkit's content displacement.
/// Apply after view-to-guest mapping, to both tracking and coasting output.
/// Hardware scrolling and dedicated trackpad gestures bypass this conversion.
public enum DirectScrollCalibration {
    public static func preciseDelta(_ guestPixels: CGPoint, directContent: Bool) -> CGPoint {
        guard directContent else { return guestPixels }
        return CGPoint(x: guestPixels.x / 12, y: guestPixels.y / 12)
    }
}
