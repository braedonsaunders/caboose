import XCTest
import UIKit
import SwiftUI
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
    func testLaptopMeasurementBeforeSelectionAndViewportChanges() throws {
        let suite = "DeviceMonitorLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(collection: collection(), monitorDefaults: defaults, startsConnections: false)
        app.setLaptopDesktop(true)
        app.laptopPhysicalPanelChanged(to: CGSize(width: 656, height: 446))
        XCTAssertNil(app.displayCapabilities())
        app.openDeviceDesktop(size: CGSize(width: 656, height: 446))
        let laptop = try XCTUnwrap(app.displayCapabilities())
        XCTAssertEqual(laptop.desktopWidth, Int(656 * app.pixelsPerPoint))
        XCTAssertEqual(laptop.desktopHeight, Int(446 * app.pixelsPerPoint))
        for size in [CGSize(width: 656, height: 300), CGSize(width: 400, height: 240)] {
            app.deviceDesktopResized(to: size)
            app.windowCardResized(to: size)
            XCTAssertEqual(app.displayCapabilities(), laptop)
        }
        app.externalDisplayConnected(size: CGSize(width: 1920, height: 1080), scale: 1)
        XCTAssertNotEqual(app.displayCapabilities(), laptop)
        app.externalDisplayDisconnected()
        XCTAssertEqual(app.displayCapabilities(), laptop)
        app.setLaptopDesktop(false)
        let base = try XCTUnwrap(app.displayCapabilities())
        XCTAssertEqual(base.desktopWidth, base.desktopHeight)
        XCTAssertEqual(base.dpi, laptop.dpi)
    }

    /// Retain the same hosted Laptop and panel size while the bound computer changes.
    /// Replacing the model avoids pairing/keychain writes and starts no connections.
    func testMountedLaptopReplaysUnchangedPanelForAnotherComputer() throws {
        let suite = "DeviceMonitorLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(LaptopLayout.Mode.laptop.rawValue, forKey: "caboose.laptop.mode")
        func app(_ name: String, dpi: Int, scale: Double) throws -> AppModel {
            let computers = collection(name)
            let identity = try XCTUnwrap(computers.active?.fileDomainIdentifier)
            var policy = MonitorPolicy()
            policy.bind(computer: identity, saved: nil)
            let selected = try XCTUnwrap(MonitorPolicy.Selection(capabilities:
                ClientCapabilities(desktopWidth: 1800, desktopHeight: 1800, dpi: dpi), renderScale: scale))
            policy.attach(selected)
            defaults.set(try XCTUnwrap(policy.saved()), forKey: "monitor.device." + identity)
            return AppModel(collection: computers, monitorDefaults: defaults, startsConnections: false)
        }
        let first = try app("first", dpi: 151, scale: 2)
        let second = try app("second", dpi: 120, scale: 1.5)
        func root(_ model: AppModel) -> some View {
            LaptopContainer { _ in Color.clear }
                .environment(model)
                .defaultAppStorage(defaults)
                .ignoresSafeArea()
        }
        let host = UIHostingController(rootView: root(first))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 656, height: 932))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        func layout() {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
        }
        layout()
        let initial = try XCTUnwrap(first.displayCapabilities())
        XCTAssertEqual(initial.desktopWidth, 1312)
        XCTAssertEqual(initial.desktopHeight, 932)
        XCTAssertEqual(initial.dpi, 151)
        XCTAssertEqual(second.displayCapabilities()?.desktopWidth, 1800)
        host.rootView = root(second) // same view identity, unchanged physical measurement
        layout()
        let rebound = try XCTUnwrap(second.displayCapabilities())
        XCTAssertEqual(rebound.desktopWidth, 984)
        XCTAssertEqual(rebound.desktopHeight, 699)
        XCTAssertEqual(rebound.dpi, 120)
        XCTAssertEqual(second.pixelsPerPoint, 1.5)
        // Persisted base dimensions and DPI remain specific to the new computer.
        let resumed = AppModel(collection: collection("second"), monitorDefaults: defaults, startsConnections: false)
        XCTAssertEqual(resumed.displayCapabilities()?.desktopWidth, 1800)
        XCTAssertEqual(resumed.displayCapabilities()?.dpi, 120)
    }

}
