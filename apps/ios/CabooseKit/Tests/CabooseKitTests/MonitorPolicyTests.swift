import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

struct MonitorPolicyTests {
    private let desktop = MonitorPolicy.Selection(capabilities: .init(desktopWidth: 1886,
        desktopHeight: 1886, dpi: 151, refreshRate: 120), renderScale: 2)!

    @Test func homeThenDesktopSelectsOnlyTheRealAttachment() throws {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        // start/resume on Home, before any presentation geometry exists.
        #expect(policy.resolve() == nil)
        #expect(policy.saved() == nil)
        #expect(policy.selection == nil)
        let attached = policy.attach(desktop)
        #expect(attached)
        #expect(policy.resolve() == desktop.capabilities)
        #expect(policy.selection?.renderScale == 2)
        let viewport = CGSize(width: 531, height: 780)
        let proposed = DeviceViewport.guestFrame(size: viewport, pixelsPerPoint: 2)
        #expect(WindowSizePolicy.request(proposed, minimum: nil, maximum: nil, fullscreen: false) == proposed)
        #expect(DisplayInfo(try #require(policy.resolve())).scale == 151.0 / 96)
    }

    @Test func resumeRestoresBeforeHomeAndDoesNotSelectFallback() throws {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        policy.attach(desktop)
        let saved = try #require(policy.saved())
        var resumed = MonitorPolicy()
        resumed.bind(computer: "computer-a", saved: saved)
        #expect(resumed.selection == desktop)
        #expect(resumed.resolve() == desktop.capabilities)
        let fallback = MonitorPolicy.Selection(capabilities: .init(desktopWidth: 2204,
            desktopHeight: 2204, dpi: 192), renderScale: 2)!
        let changed = resumed.attach(fallback)
        #expect(!changed)
        #expect(resumed.selection == desktop)
    }

    @Test func keyboardFoldRotationAndCardsCannotReplaceChosenOutput() {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        policy.attach(desktop)
        var viewport = DeviceViewport()
        for size in [CGSize(width: 531, height: 500), CGSize(width: 1102, height: 851),
                     CGSize(width: 851, height: 1102)] {
            viewport.updateDesktop(size)
            viewport.presentCard()
            viewport.updateCard(size)
            let other = MonitorPolicy.Selection(capabilities: MonitorPolicy.fullDevice(screen: size,
                pixelsPerPoint: 2, dpi: 192, refreshRate: 60), renderScale: 2)!
            let changed = policy.attach(other)
            #expect(!changed)
            #expect(policy.resolve() == desktop.capabilities)
            viewport.dismissCard()
        }
    }

    @Test func externalBeforeOrAfterDeviceNeverOverwritesSavedDevice() throws {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        let external = ClientCapabilities(desktopWidth: 3840, desktopHeight: 2160, dpi: 192)
        #expect(policy.resolve(external: external) == external)
        #expect(policy.saved() == nil)
        #expect(policy.resolve() == nil)
        policy.attach(desktop)
        _ = policy.resolve(external: external)
        var restored = MonitorPolicy()
        restored.bind(computer: "computer-a", saved: try #require(policy.saved()))
        #expect(restored.selection == desktop)
        #expect(policy.resolve() == desktop.capabilities)
    }

    @Test func foreignCorruptAndUnboundedSavedModesRemainUnselected() throws {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        policy.attach(desktop)
        let saved = try #require(policy.saved())
        var foreign = MonitorPolicy()
        foreign.bind(computer: "computer-b", saved: saved)
        #expect(foreign.selection == nil)
        let validJSON = try #require(String(data: saved, encoding: .utf8))
        for damaged in [Data("broken".utf8), Data(),
                        Data(validJSON.replacingOccurrences(of: "1886", with: "-1").utf8),
                        Data(validJSON.replacingOccurrences(of: "151", with: "999999").utf8),
                        Data(repeating: 0, count: 4097)] {
            var restored = MonitorPolicy()
            restored.bind(computer: "computer-a", saved: damaged)
            #expect(restored.selection == nil)
        }
        policy.bind(computer: "computer-b", saved: nil)
        #expect(policy.resolve() == nil)
        policy.bind(computer: nil, saved: saved)
        #expect(policy.resolve() == nil)
    }

    @Test func explicitZoomPersistsDPIWithoutChangingRenderScaleOrMode() throws {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        policy.attach(desktop)
        policy.zoomDevice(by: 1.2)
        for invalid in [0.0, -1, .infinity, .nan] { policy.zoomDevice(by: invalid) }
        var resumed = MonitorPolicy()
        resumed.bind(computer: "computer-a", saved: try #require(policy.saved()))
        #expect(resumed.device?.dpi == 181)
        #expect(resumed.device?.desktopWidth == 1886)
        #expect(resumed.selection?.renderScale == 2)
    }
    @Test func physicalLaptopModeKeepsDensityAndRestoresBase() throws {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        // Physical measurement can arrive before the first DPI selection.
        policy.presentLaptop(panel: CGSize(width: 656, height: 446))
        #expect(policy.resolve() == nil)
        policy.attach(desktop)
        let saved = try #require(policy.saved())
        #expect(policy.resolve()?.desktopWidth == 1312)
        #expect(policy.resolve()?.desktopHeight == 892)
        #expect(policy.resolve()?.dpi == desktop.capabilities.dpi)
        #expect(policy.selection == desktop)
        for input in LaptopLayout.Input.allCases {
            for keyboard in [CGFloat(0), 300, 600] {
                _ = LaptopLayout.trackpadHeight(input, available: 400)
                _ = LaptopLayout.frames(size: CGSize(width: 656, height: 932),
                    division: CGRect(x: 0, y: 446, width: 656, height: 40), keyboard: keyboard)
                #expect(policy.resolve()?.desktopHeight == 892)
            }
        }
        // Only a new physical posture/rotation changes the panel mode.
        policy.presentLaptop(panel: CGSize(width: 932, height: 308))
        #expect(policy.resolve()?.desktopWidth == 1864)
        #expect(policy.resolve()?.desktopHeight == 616)
        #expect(policy.resolve()?.dpi == desktop.capabilities.dpi)
        let external = ClientCapabilities(desktopWidth: 3840, desktopHeight: 2160, dpi: 192)
        #expect(policy.resolve(external: external) == external)
        #expect(policy.resolve()?.desktopHeight == 616)
        #expect(policy.saved() == saved)
        var restored = MonitorPolicy()
        restored.bind(computer: "computer-a", saved: saved)
        #expect(restored.laptopPanel == nil)
        #expect(restored.resolve() == desktop.capabilities)
        policy.presentLaptop(panel: nil)
        #expect(policy.resolve() == desktop.capabilities)
        policy.presentLaptop(panel: CGSize(width: 656, height: 446))
        policy.bind(computer: "computer-b", saved: nil)
        #expect(policy.laptopPanel == nil)
    }

    @Test func invalidPhysicalMeasurementsCannotReplacePanel() {
        var policy = MonitorPolicy()
        policy.bind(computer: "computer-a", saved: nil)
        policy.attach(desktop)
        policy.presentLaptop(panel: CGSize(width: 656, height: 446))
        let selected = policy.resolve()
        for invalid in [CGSize.zero, CGSize(width: CGFloat.nan, height: 10),
                        CGSize(width: 10, height: CGFloat.infinity), CGSize(width: -1, height: 10)] {
            let changed = policy.presentLaptop(panel: invalid)
            #expect(!changed)
            #expect(policy.resolve() == selected)
        }
        policy.zoomDevice(by: 1.2)
        #expect(policy.resolve()?.dpi == 181)
        #expect(policy.resolve()?.desktopWidth == selected?.desktopWidth)
        #expect(policy.selection?.renderScale == 2)
    }

}
