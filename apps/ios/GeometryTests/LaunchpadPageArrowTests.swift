import XCTest
@testable import Caboose

@MainActor
final class LaunchpadPageArrowTests: XCTestCase {
    func testSearchFiltersAllPagesAndResetsToTheFirstPage() {
        let desktop = DesktopModel(pixelsPerPoint: 2)
        let apps: [HostClient.App] = [
            .init(id: "steam", name: "Steam", icon: "", categories: [], exec: ""),
            .init(id: "cafe", name: "Café", icon: "", categories: [], exec: ""),
        ]
        desktop.launcherPage = 2
        desktop.launcherSearch = "  STEAM  "
        XCTAssertEqual(desktop.matchingLauncherApps(apps).map(\.id), ["steam"])
        XCTAssertEqual(desktop.launcherPage, 0)
        desktop.launcherSearch = "cafe"
        XCTAssertEqual(desktop.matchingLauncherApps(apps).map(\.id), ["cafe"])
        desktop.launcherSearch = "missing"
        XCTAssertTrue(desktop.matchingLauncherApps(apps).isEmpty)
        desktop.launcherSearch = ""
        XCTAssertEqual(desktop.matchingLauncherApps(apps), apps)
    }

    func testSearchControlsHaveTheirOwnPointerTargets() {
        let desktop = DesktopModel(pixelsPerPoint: 2)
        desktop.launchpadOpen = true
        desktop.launcherSearchFrame = CGRect(x: 100, y: 12, width: 300, height: 44)
        desktop.launcherClearSearchFrame = CGRect(x: 360, y: 16, width: 32, height: 32)
        XCTAssertEqual(desktop.hitTest(CGPoint(x: 120, y: 30), windows: [:]), .launcherSearch)
        XCTAssertEqual(desktop.hitTest(CGPoint(x: 375, y: 30), windows: [:]), .launcherClearSearch)
    }

    func testRepeatedClicksAdvanceToThirdPageAndStayAtTheEnd() {
        let desktop = DesktopModel(pixelsPerPoint: 2)
        desktop.launchpadOpen = true
        desktop.launcherPageCount = 3
        desktop.launcherPageFrames[-1] = CGRect(x: 100, y: 500, width: 44, height: 44)
        desktop.launcherPageFrames[1] = CGRect(x: 300, y: 500, width: 44, height: 44)
        let point = CGPoint(x: 320, y: 520)

        // Geometry stays unchanged: it must not need to be registered again after a click.
        for expectedPage in [1, 2, 2] {
            let hit = desktop.hitTest(point, windows: [:])
            XCTAssertEqual(hit, .launcherPage(1))
            if case .launcherPage(let direction) = hit { desktop.turnLauncherPage(direction) }
            XCTAssertEqual(desktop.launcherPage, expectedPage)
            XCTAssertTrue(desktop.launchpadOpen)
        }
        desktop.turnLauncherPage(-1)
        XCTAssertEqual(desktop.launcherPage, 1)
        desktop.turnLauncherPage(-1)
        desktop.turnLauncherPage(-1)
        XCTAssertEqual(desktop.launcherPage, 0)
        XCTAssertTrue(desktop.launchpadOpen)
    }
}
