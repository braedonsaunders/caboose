import CoreGraphics

/// Desktop coordinates are in points. A normal window's frame starts at its title bar;
/// its height counts only the remote content below that bar.
public enum DesktopGeometry {
    public static func maximizedFrame(size: CGSize, titleBarHeight: CGFloat,
                                      dockHeight: CGFloat, dockBottomInset: CGFloat,
                                      dockGap: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: max(1, size.width),
               height: max(1, size.height - dockHeight - dockBottomInset - dockGap - titleBarHeight))
    }

    /// The entire remote picture stays visible, including while a new size is arriving.
    /// During resize it stretches to the tile; otherwise minimum-size windows fit inside it.
    public static func surfaceFrame(natural: CGSize, available: CGSize, resizing: Bool) -> CGRect {
        guard natural.width > 0, natural.height > 0, available.width > 0, available.height > 0 else {
            return CGRect(origin: .zero, size: available)
        }
        if resizing { return CGRect(origin: .zero, size: available) }
        let scale = min(1, available.width / natural.width, available.height / natural.height)
        let shown = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: max(0, (available.width - shown.width) / 2),
                      y: scale < 1 ? 0 : max(0, (available.height - shown.height) / 2),
                      width: shown.width, height: shown.height)
    }
}
