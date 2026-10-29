import CoreGraphics
import Testing
@testable import CabooseKit

struct DesktopChromeTests {
    @Test func keyboardSafeAreaNeverBecomesDockPadding() {
        let visible = CGSize(width: 930, height: 380)
        for keyboardInset in [CGFloat(0), 34, 290, 430] {
            let bottom = DesktopChrome.dockBottomPadding(contentInset: keyboardInset, windowInset: 34)
            let workspace = DesktopChrome.workspaceSize(in: visible, dockHeight: 64, bottomInset: bottom)
            #expect(bottom <= 24)
            #expect(workspace.height >= 286)
            #expect(workspace.height + 64 + 6 + bottom == visible.height)
        }
        #expect(DesktopChrome.dockBottomPadding(contentInset: 430, windowInset: 0) == 6)
        #expect(DesktopChrome.dockBottomPadding(contentInset: 0, windowInset: 34) == 6)
        #expect(DesktopChrome.dockBottomPadding(contentInset: 34, windowInset: 34) == 24)
    }

    @Test func desktopKeepsNavigationUnlessLaptopProvidesItsReplacement() {
        for tab in ShellTab.allCases {
            #expect(!DesktopChrome.hidesShell(tab: tab, laptopDesktop: false, laptopTerminal: false))
            #expect(DesktopChrome.hidesShell(tab: tab, laptopDesktop: true, laptopTerminal: false) == (tab == .desktop))
            #expect(DesktopChrome.hidesShell(tab: tab, laptopDesktop: false, laptopTerminal: true) == (tab == .terminal))
        }
    }

    @Test func fullscreenWorkspaceLeavesTheDockVisibleAcrossFolding() {
        for size in [CGSize(width: 466, height: 678), CGSize(width: 686, height: 980), CGSize(width: 980, height: 686)] {
            let workspace = DesktopChrome.workspaceSize(in: size, dockHeight: 64, bottomInset: 8)
            #expect(workspace.width == size.width)
            #expect(workspace.height + 64 + 6 + 8 == size.height)
        }
        #expect(DesktopChrome.workspaceSize(in: .zero, dockHeight: 64, bottomInset: 8) == .zero)
    }

    @Test func widePortraitOverridesWidthBasedAndSystemTabs() {
        // Open Duo and iPad portrait windows use compact controls in the dock.
        for size in [CGSize(width: 686, height: 980),
                     CGSize(width: 768, height: 1024), CGSize(width: 1024, height: 1366)] {
            #expect(DesktopChrome.usesCompactPanel(size: size))
            #expect(!DesktopChrome.usesCompactPanel(size: CGSize(width: size.height, height: size.width)))
        }
    }

    @Test func closedPhoneKeepsItsNativeSidebar() {
        for width in [390.0, 402, 466, 599] {
            #expect(!DesktopChrome.usesCompactPanel(size: CGSize(width: width, height: 844)))
        }
        #expect(DesktopChrome.usesCompactPanel(size: CGSize(width: 600, height: 844)))
    }

    @Test func squareWindowKeepsCompactControls() {
        #expect(DesktopChrome.usesCompactPanel(size: CGSize(width: 800, height: 800)))
    }

    @Test func unknownOrInvalidWindowDoesNotSelectPortrait() {
        for size in [CGSize.zero, CGSize(width: 0, height: 844),
                     CGSize(width: -1, height: 844), CGSize(width: 390, height: CGFloat.infinity),
                     CGSize(width: CGFloat.nan, height: 844)] {
            #expect(!DesktopChrome.usesCompactPanel(size: size))
        }
    }
}
