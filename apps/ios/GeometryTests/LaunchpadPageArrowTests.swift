import XCTest
@testable import Caboose

@MainActor
final class LaunchpadPageArrowTests: XCTestCase {
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
