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
}
