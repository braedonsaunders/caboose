import XCTest
import SwiftUI
import UIKit
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

@MainActor
final class DesktopPanelPointerTests: XCTestCase {
    func testLaptopMenuRowsUseTheVisibleOverlayScaleFromBottomToTop() throws {
        let model = AppModel(collection: .init(), startsConnections: false)
        model.setLaptopDesktop(true)
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 420)
        let items = ["Trackpad", "Keyboard & Trackpad", "Keyboard", "Gamepad", "Trackpad Gestures",
                     "Wallpaper", "Computer Settings", "Task Manager", "Park Computer", "Terminal"]
            .map { SceneMenuItem(title: $0, systemImage: "circle", perform: {}) }
        let reference = SceneMenu()
        reference.show(items, at: CGPoint(x: 850, y: 390), above: true)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func settle() {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        host.rootView = AnyView(SceneMenuView(menu: reference, space: "laptop", bounds: bounds, ui: 0.84)
            .frame(width: bounds.width, height: bounds.height)
            .coordinateSpace(name: "laptop"))
        settle()
        let visibleRows = reference.rows
        XCTAssertEqual(visibleRows.count, items.count)

        model.desktop.menu.show(items, at: CGPoint(x: 850, y: 390), above: true)
        host.rootView = AnyView(ZStack(alignment: .topLeading) {
            DesktopStage().environment(\.laptopInputOwned, true)
            SceneMenuView(menu: model.desktop.menu, space: "laptop", bounds: bounds, ui: 0.84)
        }
        .frame(width: bounds.width, height: bounds.height)
        .coordinateSpace(name: "laptop")
        .environment(model))
        settle()
        // Laptop's legible overlay stays at .84 while the desktop underneath changes scale.
        // A second menu there must not overwrite the visible menu's row measurements.
        for scale in [0.60, 0.72, 0.82] {
            model.desktop.ui = scale
            settle()
            for index in items.indices.reversed() {
                let row = try XCTUnwrap(visibleRows[index])
                XCTAssertEqual(model.desktop.menu.hit(CGPoint(x: row.midX, y: row.midY)), index,
                               "\(items[index]) at desktop scale \(scale)")
                let measured = try XCTUnwrap(model.desktop.menu.rows[index])
                XCTAssertEqual(measured.minY, row.minY, accuracy: 1)
                XCTAssertEqual(measured.height, row.height, accuracy: 1)
            }
        }
    }
}
