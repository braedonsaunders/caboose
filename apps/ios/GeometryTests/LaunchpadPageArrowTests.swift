import XCTest
@testable import Caboose

@MainActor
final class LaunchpadPageArrowTests: XCTestCase {
    func testClickWhereTheLastPageArrowWasStaysInLaunchpad() {
        let desktop = DesktopModel(pixelsPerPoint: 2)
        desktop.launchpadOpen = true
        desktop.launcherPage = 1
        // On the last page the forward arrow is the dimmed one, registered as direction 0.
        desktop.launcherPageFrames[-1] = CGRect(x: 100, y: 500, width: 44, height: 44)
        desktop.launcherPageFrames[0] = CGRect(x: 300, y: 500, width: 44, height: 44)

        let hit = desktop.hitTest(CGPoint(x: 320, y: 520), windows: [:])
        XCTAssertEqual(hit, .launcherPage(0))
        desktop.turnLauncherPage(0)
        XCTAssertTrue(desktop.launchpadOpen)
        XCTAssertEqual(desktop.launcherPage, 1)

        desktop.turnLauncherPage(-1)
        XCTAssertEqual(desktop.launcherPage, 0)
        XCTAssertTrue(desktop.launchpadOpen)
    }
}
