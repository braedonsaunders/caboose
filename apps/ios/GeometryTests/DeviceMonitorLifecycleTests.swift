import XCTest
import UIKit
@testable import Caboose
@testable import CabooseKit

@MainActor
final class DeviceMonitorLifecycleTests: XCTestCase {
    private func collection(_ name: String = "a") -> Credentials.Collection {
        var result = Credentials.Collection()
        _ = result.select(Credentials(hostURL: URL(string: "https://\(name).example.invalid")!, token: "test-only"))
        return result
    }

    func testUncachedHomeThenMeasuredDesktopPreservesInitialDPIAndScale() throws {
        let suite = "DeviceMonitorLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let computers = collection()
        let app = AppModel(collection: computers, monitorDefaults: defaults, startsConnections: false)
        app.desktopZoom = 1
        XCTAssertEqual(app.selectedTab, .home)
        XCTAssertNil(app.displayCapabilities()) // same method used before start and resume
        XCTAssertNil(app.displayCapabilities()) // another Home/reconnect pass cannot seal 192 DPI
        let size = CGSize(width: 531, height: 780)
        app.selectedTab = .desktop
        app.openDeviceDesktop(size: size)
        let scale = min(2, max(1, UIScreen.main.scale))
        let ui = DesktopModel.deviceUI(forWidth: size.width)
        let expectedDPI = Int((96 * scale * ui).rounded())
        let chosen = try XCTUnwrap(app.displayCapabilities())
        XCTAssertEqual(chosen.dpi, expectedDPI)
        XCTAssertEqual(app.desktop.pixelsPerPoint, scale)
        XCTAssertEqual(app.desktop.ui, ui) // no initial ordinary-window visual enlargement
        XCTAssertEqual(DeviceViewport.guestFrame(size: size, pixelsPerPoint: app.desktop.pixelsPerPoint),
                       CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        for stage in [CGSize(width: 531, height: 400), CGSize(width: 1102, height: 851), CGSize(width: 851, height: 1102)] {
            app.deviceDesktopResized(to: stage)
            XCTAssertEqual(app.displayCapabilities(), chosen)
        }
        let resizedUI = app.desktop.ui
        app.closeDeviceDesktop()
        app.openDeviceDesktop(size: CGSize(width: 851, height: 1102))
        XCTAssertEqual(app.desktop.ui, resizedUI) // reentry uses the same width/owner zoom
        XCTAssertEqual(app.displayCapabilities(), chosen)
        app.closeDeviceDesktop()
        app.presentedWindowID = 42
        app.windowCardResized(to: CGSize(width: 531, height: 600))
        XCTAssertEqual(app.displayCapabilities(), chosen)

        let resumed = AppModel(collection: computers, monitorDefaults: defaults, startsConnections: false)
        XCTAssertEqual(resumed.selectedTab, .home)
        XCTAssertEqual(resumed.displayCapabilities(), chosen)
        XCTAssertEqual(resumed.pixelsPerPoint, scale)
        resumed.desktopZoom = 1
        resumed.openDeviceDesktop(size: CGSize(width: 1102, height: 851))
        XCTAssertEqual(resumed.desktop.pixelsPerPoint, scale)
        XCTAssertEqual(resumed.desktop.ui, DesktopModel.deviceUI(forWidth: 1102))
        XCTAssertEqual(resumed.displayCapabilities(), chosen)
    }

    func testCardFirstAndExternalPrecedenceDoNotRewriteDevicePreference() throws {
        let suite = "DeviceMonitorLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let computers = collection()
        let app = AppModel(collection: computers, monitorDefaults: defaults, startsConnections: false)
        XCTAssertNil(app.displayCapabilities())
        app.externalDisplayConnected(size: CGSize(width: 1920, height: 1080), scale: 1)
        XCTAssertNotNil(app.displayCapabilities())
        let key = "monitor.device." + computers.active!.fileDomainIdentifier
        XCTAssertNil(defaults.data(forKey: key))
        app.externalDisplayDisconnected()
        XCTAssertNil(app.displayCapabilities())
        app.presentedWindowID = 7
        app.windowCardResized(to: .zero)
        XCTAssertNil(app.displayCapabilities())
        app.windowCardResized(to: CGSize(width: 531, height: 700))
        let selected = try XCTUnwrap(app.displayCapabilities())
        XCTAssertEqual(selected.dpi, 192)
        let saved = try XCTUnwrap(defaults.data(forKey: key))
        app.externalDisplayConnected(size: CGSize(width: 3840, height: 2160), scale: 2)
        XCTAssertNotEqual(app.displayCapabilities(), selected)
        XCTAssertEqual(defaults.data(forKey: key), saved)
        app.externalDisplayDisconnected()
        XCTAssertEqual(app.displayCapabilities(), selected)
        let foreign = collection("foreign")
        defaults.set(saved, forKey: "monitor.device." + foreign.active!.fileDomainIdentifier)
        let other = AppModel(collection: foreign, monitorDefaults: defaults, startsConnections: false)
        XCTAssertNil(other.displayCapabilities())
    }
}
