import CoreGraphics

/// Video and the window picture share one coordinate space, even while the view is
/// stretching an old picture during a guest resize. The outer Yard transform applies once
/// to both. Clipping never changes the scale or origin of the complete decoded picture.
public struct VideoLayerGeometry: Equatable {
    public let container: CGRect
    public let picture: CGRect

    public init?(rect: CGRect, clip: CGRect?, surfaceSize: CGSize, bounds: CGRect) {
        guard surfaceSize.width > 0, surfaceSize.height > 0,
              bounds.width > 0, bounds.height > 0, rect.width > 0, rect.height > 0 else { return nil }
        let visible = (clip ?? rect).intersection(rect)
            .intersection(CGRect(origin: .zero, size: surfaceSize))
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let sx = bounds.width / surfaceSize.width, sy = bounds.height / surfaceSize.height
        container = CGRect(x: bounds.minX + visible.minX * sx, y: bounds.minY + visible.minY * sy,
                           width: visible.width * sx, height: visible.height * sy)
        picture = CGRect(x: (rect.minX - visible.minX) * sx, y: (rect.minY - visible.minY) * sy,
                         width: rect.width * sx, height: rect.height * sy)
    }
}
