import CoreGraphics

/// Vulkan draws in authenticated server pixels. UIKit fitting does not change
/// the drawable extent or require multiplying it by the phone screen scale.
enum LiveGPUDrawableGeometry {
    static func extent(serverPixels: CGSize, visibleBounds: CGSize) -> CGSize? {
        guard visibleBounds.width.isFinite, visibleBounds.height.isFinite,
              visibleBounds.width > 0, visibleBounds.height > 0 else { return nil }
        for value in [serverPixels.width, serverPixels.height] {
            guard value.isFinite, value >= 1, value <= CGFloat(UInt32.max),
                  value.rounded(.towardZero) == value else { return nil }
        }
        return serverPixels
    }
}
