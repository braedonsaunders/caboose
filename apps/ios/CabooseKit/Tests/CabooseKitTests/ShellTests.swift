import XCTest
@testable import CabooseKit

final class AppShortcutsTests: XCTestCase {
    func testPinningKeepsOrderAndTogglesOff() {
        var shortcuts = AppShortcuts()
        shortcuts.togglePin("b.desktop")
        shortcuts.togglePin("a.desktop")
        XCTAssertEqual(shortcuts.pinned, ["b.desktop", "a.desktop"])
        shortcuts.togglePin("b.desktop")
        XCTAssertEqual(shortcuts.pinned, ["a.desktop"])
        XCTAssertTrue(shortcuts.isPinned("a.desktop"))
        XCTAssertFalse(shortcuts.isPinned("b.desktop"))
    }

    func testRecentMovesToFrontWithoutDuplicatesAndIsCapped() {
        var shortcuts = AppShortcuts()
        for index in 0 ..< 20 { shortcuts.recordOpen("app\(index)") }
        shortcuts.recordOpen("app15")
        XCTAssertEqual(shortcuts.recent.count, AppShortcuts.recentLimit)
        XCTAssertEqual(shortcuts.recent.first, "app15")
        XCTAssertEqual(shortcuts.recent.filter { $0 == "app15" }.count, 1)
        XCTAssertEqual(shortcuts.recent[1], "app19")
    }

    func testRecentSkipsPinnedAndMissingApps() {
        var shortcuts = AppShortcuts()
        ["a", "b", "c", "d"].forEach { shortcuts.recordOpen($0) }
        shortcuts.togglePin("c")
        let available: Set = ["a", "b", "c"]
        XCTAssertEqual(shortcuts.recentApps(available: available, limit: 8), ["b", "a"])
        XCTAssertEqual(shortcuts.recentApps(available: available, limit: 1), ["b"])
        XCTAssertEqual(shortcuts.pinnedApps(available: ["a", "b"]), [])
        XCTAssertEqual(shortcuts.pinnedApps(available: available), ["c"])
    }

    func testCodableRoundTrip() throws {
        var shortcuts = AppShortcuts()
        shortcuts.togglePin("x")
        shortcuts.recordOpen("y")
        let data = try JSONEncoder().encode(shortcuts)
        XCTAssertEqual(try JSONDecoder().decode(AppShortcuts.self, from: data), shortcuts)
    }
}

final class ShellLinkTests: XCTestCase {
    func testTabsTasksAndAirPlay() {
        XCTAssertEqual(ShellLink(URL(string: "caboose://home")!), .tab(.home))
        XCTAssertEqual(ShellLink(URL(string: "caboose://Desktop")!), .tab(.desktop))
        XCTAssertEqual(ShellLink(URL(string: "caboose://agents")!), .tab(.agents))
        XCTAssertEqual(ShellLink(URL(string: "caboose://apps")!), .tab(.apps))
        XCTAssertEqual(ShellLink(URL(string: "caboose://terminal")!), .tab(.terminal))
        XCTAssertEqual(ShellLink(URL(string: "caboose://task/abc123")!), .task("abc123"))
        XCTAssertEqual(ShellLink(URL(string: "caboose://airplay")!), .airPlay)
    }

    func testOtherLinksAreNotShellLinks() {
        XCTAssertNil(ShellLink(URL(string: "caboose://connect?host=http://h&token=t")!))
        XCTAssertNil(ShellLink(URL(string: "caboose://task")!))
        XCTAssertNil(ShellLink(URL(string: "https://home")!))
        XCTAssertNil(ShellLink(URL(string: "caboose://settings")!))
    }
}

final class AirPlayRouteTests: XCTestCase {
    private let speaker = AirPlayRoute.Output(type: "Speaker", uid: "Speaker", name: "Speaker")
    private let tv = AirPlayRoute.Output(type: "AirPlay", uid: "AA:BB-airplay", name: "Living Room")

    func testRemembersTheDevicePlayingNow() {
        XCTAssertEqual(AirPlayRoute.remembered(after: [tv], previous: nil), AirPlayRoute(uid: "AA:BB-airplay", name: "Living Room"))
        let other = AirPlayRoute(uid: "old", name: "Bedroom")
        XCTAssertEqual(AirPlayRoute.remembered(after: [speaker, tv], previous: other)?.name, "Living Room")
    }

    func testLeavingAirPlayKeepsTheLastDevice() {
        let last = AirPlayRoute(uid: "AA:BB-airplay", name: "Living Room")
        XCTAssertEqual(AirPlayRoute.remembered(after: [speaker], previous: last), last)
        XCTAssertNil(AirPlayRoute.remembered(after: [speaker], previous: nil))
        XCTAssertNil(AirPlayRoute.active(in: [speaker]))
    }

    func testAnOutputWithoutIdentityIsIgnored() {
        XCTAssertNil(AirPlayRoute.active(in: [AirPlayRoute.Output(type: "AirPlay", uid: "", name: "TV")]))
    }
}

final class VisibleRecentFilesTests: XCTestCase {
    func testHiddenFilesAndDirectoriesAreLeftOut() {
        let files = [
            RecentFile(path: ".config/chromium/Default/Cookies", mtime: 9),
            RecentFile(path: "Documents/report.odt", mtime: 8),
            RecentFile(path: ".bashrc", mtime: 7),
            RecentFile(path: "Projects/app/.git/index", mtime: 6),
            RecentFile(path: "Downloads/photo.jpg", mtime: 5),
            RecentFile(path: "notes.txt", mtime: 4),
        ]
        XCTAssertEqual(RecentFiles.visible(files, limit: 8).map(\.path), ["Documents/report.odt", "Downloads/photo.jpg", "notes.txt"])
        XCTAssertEqual(RecentFiles.visible(files, limit: 2).map(\.path), ["Documents/report.odt", "Downloads/photo.jpg"])
    }
}

final class LaunchpadLayoutTests: XCTestCase {
    func testABigScreenGetsSevenFullColumns() {
        let layout = LaunchpadLayout(size: CGSize(width: 1920, height: 1080), ui: 1.2, dockHeight: 76 * 1.2)
        XCTAssertEqual(layout.columns, 7)
        XCTAssertEqual(layout.column, 150 * 1.2, accuracy: 0.001)
        XCTAssertLessThanOrEqual(layout.width, 1920)
    }

    func testANarrowPhoneDesktopFitsInsideItsWidth() {
        // iPhone Duo closed, beside the vertical bar: about 375 by 678 points at ui 0.72.
        for width in [320.0, 375.0, 430.0, 700.0] {
            let layout = LaunchpadLayout(size: CGSize(width: width, height: 678), ui: 0.72, dockHeight: 76 * 0.72)
            XCTAssertLessThanOrEqual(layout.width, width - 2 * 24 * 0.72 + 0.001, "width \(width)")
            XCTAssertGreaterThanOrEqual(layout.columns, 2)
            XCTAssertLessThanOrEqual(layout.icon, layout.column)
            XCTAssertGreaterThanOrEqual(layout.rows, 1)
        }
    }
}

final class HostMessageTests: XCTestCase {
    func testARepeatedLineAppearsOnce() {
        let raw = Array(repeating: "docker exec failed: container caboose-owner is not running", count: 60).joined(separator: "\n")
        XCTAssertEqual(HostMessage.clipped(raw), "docker exec failed: container caboose-owner is not running")
    }

    func testLongMessagesAreHeldToAFewLinesAndCharacters() {
        let raw = (1 ... 10).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(HostMessage.clipped(raw, maxLines: 3), "line 1\nline 2\nline 3…")
        let long = String(repeating: "x", count: 1000)
        let clipped = HostMessage.clipped(long, maxCharacters: 100)
        XCTAssertEqual(clipped.count, 100)
        XCTAssertTrue(clipped.hasSuffix("…"))
    }

    func testUpgradeStates() {
        XCTAssertEqual(HostMessage.upgradeStatus("failed"), "Update Failed")
        XCTAssertEqual(HostMessage.upgradeStatus("updating"), "Updating")
        XCTAssertNil(HostMessage.upgradeStatus("idle"))
    }
}
