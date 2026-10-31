import Foundation
import Metal
import QuartzCore
import Testing
@testable import CabooseKit

/// The controller end to end on this machine's GPU: a window surface whose app scrolls its
/// picture as forwarded scroll arrives, captured, measured off the main thread and composed.
@MainActor
struct LocalScrollControllerTests {
    @Test func flickComposesThenHandsBackAtTheAppsPosition() async throws {
        guard let controller = LocalScrollController(enabled: true) else { return }
        let width = 240, height = 480, header = 40, scale = 2.0
        let page = LocalScrollRendererTests.picture(width: width, height: 6000, seed: 21)
        let surface = WindowSurface()
        surface.resize(width: width, height: height)
        var appOffset = 1000.0
        func draw() {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let offset = Int(appOffset.rounded())
            for y in 0..<height {
                let row = y < header ? y : y + offset
                bytes.replaceSubrange((y * width * 4)..<((y + 1) * width * 4), with: page[(row * width * 4)..<((row + 1) * width * 4)])
            }
            bytes.withUnsafeBytes { surface.upload(bgra: $0.baseAddress!, rowBytes: width * 4, x: 0, y: 0, width: width, height: height) }
        }
        draw()
        let layer = CAMetalLayer()
        layer.device = SurfaceRenderer.shared.device
        layer.pixelFormat = .bgra8Unorm
        var inbound: [(due: Int, delta: Double)] = []
        var refresh = 0, composed = 0, sent = 0.0
        var t = CACurrentMediaTime()
        func step() async {
            refresh += 1
            t += 1.0 / 120
            // The app applies scroll four refreshes after it is sent and redraws.
            let due = inbound.filter { $0.due <= refresh }
            if !due.isEmpty {
                inbound.removeAll { $0.due <= refresh }
                appOffset = min(5000 - Double(height), max(0, appOffset + due.reduce(0) { $0 + $1.delta }))
                draw()
            }
            if controller.refresh(at: t, surface: surface, layer: layer) { composed += 1 }
            if ProcessInfo.processInfo.environment["CABOOSE_SCROLL_TRACE"] == "1", refresh % 10 == 0 || refresh < 40 {
                let m = controller.model
                print("r\(refresh) \(m.phase) pos \(Int(m.position)) cmd \(Int(m.commanded)) placed \(m.placedOffset.map { Int($0) } ?? -1) app \(Int(appOffset - 1000)) sent \(Int(sent)) frames \(m.retainedFrames.count) region \(String(describing: m.region))")
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        // Let the window be captured once at rest.
        controller.begin(at: t, delta: CGPoint(x: 0, y: 1), anchor: CGPoint(x: 120, y: 300),
                         scale: CGSize(width: scale, height: scale)) { delta, _ in
            sent += Double(delta.y)
            inbound.append((refresh + 4, Double(delta.y)))
            return true
        }
        // A flick: 12 refreshes of finger movement in points, then release.
        for _ in 0..<12 {
            await step()
            controller.track(CGPoint(x: 0, y: 12), at: t)
        }
        controller.release(at: t, velocity: CGPoint(x: 0, y: 1400), coast: true)
        var rest = 0
        while rest < 30, refresh < 2000 {
            await step()
            rest = controller.isActive ? 0 : rest + 1
        }
        #expect(composed > 30)
        #expect(sent > 400)
        #expect(!controller.isActive)
        // At rest the phone shows the app's own picture, which is where the phone scrolled to.
        let start = 1000.0
        #expect(abs((appOffset - start) - controller.model.position) <= 1)
    }
}
