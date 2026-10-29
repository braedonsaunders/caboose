import CoreGraphics

/// Desktop chrome follows the shell window, never the keyboard-reduced content area.
/// Wide portrait windows use the dock panel; a closed phone keeps its native shell bar.
public enum DesktopChrome {
    public static func usesCompactPanel(size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 600, size.height > 0 else { return false }
        return size.height >= size.width
    }
}
