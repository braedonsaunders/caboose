import CoreGraphics

/// Desktop chrome follows the shell window, never the keyboard-reduced content area.
/// Wide portrait windows use the dock panel; a closed phone keeps its native shell bar.
public enum DesktopChrome {
    /// The dock clears the home indicator. A descendant's safe area can include the
    /// software keyboard even when its proposed height has already been shortened.
    /// Only the part belonging to the window's system chrome can become dock padding.
    public static func dockBottomPadding(contentInset: CGFloat, windowInset: CGFloat) -> CGFloat {
        max(6, min(max(0, contentInset), max(0, windowInset)) - 10)
    }

    /// Fullscreen Linux content stays inside Desktop's workspace. Only Laptop supplies
    /// replacement shell controls; app cards are presented outside the tab shell.
    public static func hidesShell(tab: ShellTab, laptopDesktop: Bool, laptopTerminal: Bool) -> Bool {
        (tab == .desktop && laptopDesktop) || (tab == .terminal && laptopTerminal)
    }

    /// Both tiled and fullscreen content end above the dock.
    public static func workspaceSize(in size: CGSize, dockHeight: CGFloat, bottomInset: CGFloat) -> CGSize {
        CGSize(width: max(0, size.width), height: max(0, size.height - dockHeight - 6 - bottomInset))
    }

    public static func usesCompactPanel(size: CGSize) -> Bool {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 600, size.height > 0 else { return false }
        return size.height >= size.width
    }
}
