import CoreGraphics

/// Desktop chrome follows the shell window, never the keyboard-reduced content area.
/// This overrides both iPad system tabs and Duo's native/custom rail in portrait.
public enum DesktopChrome {
    public static func usesCompactPanel(size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }
        return size.height >= size.width
    }
}
