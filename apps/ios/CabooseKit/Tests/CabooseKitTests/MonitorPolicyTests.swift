import CoreGraphics
import Testing
@testable import CabooseKit

struct MonitorPolicyTests {
    @Test func fullDeviceRetainsChosenDesktopDPIAndRenderScale() {
        let screen = CGSize(width: 531, height: 943)
        let selected = MonitorPolicy.fullDevice(screen: screen, pixelsPerPoint: 2, dpi: 151, refreshRate: 120)
        #expect(selected.desktopWidth == 1886 && selected.desktopHeight == 1886)
        #expect(selected.dpi == 151)
        #expect(DisplayInfo(selected).scale == 151.0 / 96)
        #expect(MonitorPolicy.fullDevice(screen: CGSize(width: 943, height: 531),
            pixelsPerPoint: 2, dpi: 151, refreshRate: 120) == selected)
        // A normal window still requests the original viewport pixels; the monitor
        // is not a request to enlarge every app or change its presentation scale.
        let viewport = CGSize(width: 531, height: 780)
        let proposed = DeviceViewport.guestFrame(size: viewport, pixelsPerPoint: 2)
        #expect(WindowSizePolicy.request(proposed, minimum: nil, maximum: nil, fullscreen: false) == proposed)
        #expect(DesktopGeometry.surfaceFrame(natural: viewport, available: viewport, resizing: false).size == viewport)
    }

    @Test func viewportEventsCannotReplaceAttachedDeviceMonitor() {
        var policy = MonitorPolicy()
        let selected = MonitorPolicy.fullDevice(screen: CGSize(width: 531, height: 943),
            pixelsPerPoint: 2, dpi: 151, refreshRate: 120)
        let attached = policy.resolve(device: selected)
        #expect(attached == selected)
        var viewport = DeviceViewport()
        for size in [CGSize(width: 531, height: 943), CGSize(width: 531, height: 500),
                     CGSize(width: 1102, height: 851), CGSize(width: 851, height: 1102)] {
            viewport.updateDesktop(size)
            viewport.presentCard()
            viewport.updateCard(size)
            let changedCandidate = MonitorPolicy.fullDevice(screen: size, pixelsPerPoint: 2, dpi: 192, refreshRate: 60)
            let resolved = policy.resolve(device: changedCandidate)
            #expect(resolved == selected)
            #expect(viewport.cardSize == size)
            viewport.dismissCard()
            #expect(policy.device == selected)
        }
    }

    @Test func externalModeWinsAndDetachmentRestoresDevice() {
        var policy = MonitorPolicy()
        let device = ClientCapabilities(desktopWidth: 1886, desktopHeight: 1886, dpi: 151)
        _ = policy.resolve(device: device)
        for external in [ClientCapabilities(desktopWidth: 2560, desktopHeight: 1440, dpi: 128),
                         ClientCapabilities(desktopWidth: 3840, desktopHeight: 2160, dpi: 192)] {
            let resolved = policy.resolve(device: .init(desktopWidth: 1, desktopHeight: 1, dpi: 96), external: external)
            #expect(resolved == external)
            #expect(policy.device == device)
        }
        let detached = policy.resolve(device: .init(desktopWidth: 100, desktopHeight: 100, dpi: 96))
        #expect(detached == device)
    }

    @Test func externalFirstDoesNotPreselectDeviceAndExplicitZoomChangesOnlyDPI() {
        var policy = MonitorPolicy()
        let fallback = ClientCapabilities(desktopWidth: 1886, desktopHeight: 1886, dpi: 192)
        let external = ClientCapabilities(desktopWidth: 2560, desktopHeight: 1440, dpi: 128)
        _ = policy.resolve(device: fallback, external: external)
        #expect(policy.device == nil)
        var chosen = fallback
        chosen.dpi = 151
        _ = policy.resolve(device: chosen)
        policy.zoomDevice(by: 1.2)
        chosen.dpi = 181
        #expect(policy.device == chosen)
        for invalid in [0.0, -1, .infinity, .nan] { policy.zoomDevice(by: invalid) }
        #expect(policy.device == chosen)
        let unchanged = policy.resolve(device: fallback)
        #expect(unchanged == chosen)
    }
}
