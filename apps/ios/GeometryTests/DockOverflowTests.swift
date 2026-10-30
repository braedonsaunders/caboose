import XCTest
import SwiftUI
import UIKit
@testable import Caboose

@MainActor
final class DockOverflowTests: XCTestCase {
    /// Render the actual dock, including its glass and scroll viewport. A solid icon
    /// makes missing rows measurable without depending on a particular application's art.
    func testLaunchingIconsRemainWholeInTiledFloatingAndCompactDocks() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Bounce measurement requires Reduce Motion to be off")
        let model = AppModel(collection: .init(), startsConnections: false)
        func icon(_ color: UIColor) -> String {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 52, height: 52)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 52, height: 52))
            }
            return "data:image/png;base64," + image.pngData()!.base64EncodedString()
        }
        let ids = ["chromium", "thunar", "xfce4-terminal", "code", "obsidian", "opencode",
                   "mousepad", "libreoffice-writer", "libreoffice-calc", "gimp"]
        model.applyApps(ids.enumerated().map { index, id in
            .init(id: id, name: id, icon: icon(index == 0 ? .red : .blue), categories: [], exec: "")
        })
        model.desktop.size = CGSize(width: 400, height: 500)
        model.desktop.ui = 1
        let size = CGSize(width: 400, height: 200)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil; model.dockLaunches.reset() }

        func snapshot() throws -> (red: CGRect, blue: CGRect) {
            window.layoutIfNeeded()
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            var bytes = [UInt8](repeating: 0, count: 400 * 200 * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 400, height: 200,
                    bitsPerComponent: 8, bytesPerRow: 400 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: size))
            }
            var red = CGRect.null, blue = CGRect.null
            for y in 0..<200 {
                for x in 0..<400 {
                    let i = (y * 400 + x) * 4
                    if bytes[i] > 240 && bytes[i + 1] < 15 && bytes[i + 2] < 15 {
                        red = red.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                    if bytes[i + 2] > 240 && bytes[i + 1] < 15 && bytes[i] < 15 {
                        blue = blue.union(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            return (red, blue)
        }
        for kind in ["tiled", "floating", "compact"] {
            model.dockLaunches.reset()
            // Hover enlarges the free desktop icon beyond the glass boundary too.
            model.desktop.hovered = kind == "floating" ? .dock(ids[0]) : .none
            let dock: AnyView
            switch kind {
            case "tiled": dock = AnyView(YardDock(yard: model.yard, width: 220))
            case "floating": dock = AnyView(Dock(desktop: model.desktop))
            default:
                // The Laptop control deck clips at the rail's top. Preserve that fence.
                dock = AnyView(Dock(desktop: model.desktop, compact: true)
                    .frame(width: 400, height: 44).clipped())
            }
            host.rootView = AnyView(dock.environment(model)
                .frame(width: 400, height: 200).background(.black).ignoresSafeArea())
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let rest = try snapshot().red
            XCTAssertFalse(rest.isNull, kind)
            XCTAssertEqual(rest.height, kind == "tiled" ? 38 : kind == "compact" ? 26 : 66, accuracy: 2, kind)
            _ = model.dockLaunches.begin(ids[0])
            var highest = rest.minY
            for _ in 0..<12 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let painted = try snapshot()
                highest = min(highest, painted.red.minY)
                XCTAssertEqual(painted.red.height, rest.height, accuracy: 2, kind)
                XCTAssertEqual(painted.red.width, rest.width, accuracy: 2, kind)
                if kind == "tiled" {
                    // 220 - 32 - (2*34 + 1 + 3*10 + 24) = 65pt app viewport.
                    XCTAssertLessThanOrEqual(painted.blue.maxX, rest.minX + 66,
                                             "Scrolled apps must not paint over Overview/All Apps")
                }
            }
            XCTAssertLessThan(highest, rest.minY - 3, "\(kind) must actually bounce")
        }
    }
}
