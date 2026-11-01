import CoreGraphics

/// Vulkan draws in authenticated server pixels. UIKit fitting does not change
/// the drawable extent or require multiplying it by the phone screen scale.
enum LiveGPUDrawableGeometry {
    /// The compositor converts requested physical pixels to integer Wayland units,
    /// then reports those units in the assigned output's pixel space.
    static func quantizedRequest(_ pixels: CGSize, scale: Double) -> CGSize? {
        guard scale.isFinite, scale > 0 else { return nil }
        func dimension(_ pixels: CGFloat) -> CGFloat? {
            guard pixels.isFinite, pixels >= 1, pixels <= CGFloat(Int32.max) else { return nil }
            let logical = max(1, (Double(pixels) / scale).rounded())
            guard logical <= Double(Int32.max) else { return nil }
            let result = (logical * scale).rounded()
            guard result.isFinite, result >= 1, result <= Double(Int32.max) else { return nil }
            return CGFloat(result)
        }
        guard let width = dimension(pixels.width), let height = dimension(pixels.height) else { return nil }
        return CGSize(width: width, height: height)
    }

    static func extent(serverPixels: CGSize, visibleBounds: CGSize, requestedPixels: CGSize? = nil) -> CGSize? {
        guard requestedPixels == nil || requestedPixels == serverPixels else { return nil }
        guard visibleBounds.width.isFinite, visibleBounds.height.isFinite,
              visibleBounds.width > 0, visibleBounds.height > 0 else { return nil }
        for value in [serverPixels.width, serverPixels.height] {
            guard value.isFinite, value >= 1, value <= CGFloat(UInt32.max),
                  value.rounded(.towardZero) == value else { return nil }
        }
        return serverPixels
    }

    /// Where a picture of `picture` pixels shows in a view's `bounds`: filling them when the
    /// picture has their shape (within half a percent, or within five percent for a full-screen
    /// window, so a game a few pixels off its window fills it), otherwise scaled with its aspect
    /// ratio to fit, centred, never stretched. An application that keeps
    /// its own resolution after its window changed size (a fold, a rotation) is scaled by
    /// the phone, never shown at its old size in a corner.
    static func placement(picture: CGSize, in bounds: CGRect, fill: Bool) -> CGRect {
        guard picture.width.isFinite, picture.height.isFinite, picture.width > 0, picture.height > 0,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / picture.width, bounds.height / picture.height)
        var size = CGSize(width: picture.width * scale, height: picture.height * scale)
        let snap: CGFloat = fill ? 0.95 : 0.995
        if size.width >= bounds.width * snap { size.width = bounds.width }
        if size.height >= bounds.height * snap { size.height = bounds.height }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
