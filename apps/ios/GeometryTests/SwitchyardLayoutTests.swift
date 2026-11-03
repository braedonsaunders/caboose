import XCTest
import UIKit
@testable import Caboose
@testable import CabooseKit

/// The app's own Switchyard (`YardModel`), fed windows as the computer announces them and
/// laid out on this Simulator's screen and on every other screen Caboose tiles on: every
/// tile obeys `TilePolicy`, and turning or folding and back restores every tile.
///
/// With `CABOOSE_LAYOUT_SHOTS` set to a directory (`TEST_RUNNER_CABOOSE_LAYOUT_SHOTS` through
/// `xcodebuild test`), each layout is also drawn there as a PNG: the whole track, one screen
/// after another, each tile with its title bar.
@MainActor
final class SwitchyardLayoutTests: XCTestCase {
    /// Workspaces above the dock, in points.
    private static let screens: [(name: String, size: CGSize)] = [
        ("duo-inner-upright", CGSize(width: 669, height: 880)),
        ("duo-inner-on-its-side", CGSize(width: 951, height: 560)),
        ("duo-outer-upright", CGSize(width: 402, height: 780)),
        ("iphone-17-pro-max-upright", CGSize(width: 440, height: 860)),
        ("iphone-17-pro-max-on-its-side", CGSize(width: 956, height: 360)),
        ("ipad-mini-upright", CGSize(width: 744, height: 1040)),
        ("ipad-pro-11-on-its-side", CGSize(width: 1210, height: 740)),
        ("ipad-pro-13-upright", CGSize(width: 1032, height: 1280)),
        ("ipad-pro-13-on-its-side", CGSize(width: 1376, height: 940)),
        ("tv-1080p", CGSize(width: 1920, height: 1000)),
    ]

    /// Window sets: titles and minimum sizes in Linux pixels.
    private static let sets: [[(title: String, minimum: CGSize?)]] = [
        [("File System - Thunar", nil), ("Settings", CGSize(width: 660, height: 480))],
        [("File System - Thunar", nil), ("Settings", CGSize(width: 660, height: 480)), ("Terminal", nil)],
        [("Chromium", CGSize(width: 900, height: 600)), ("File System - Thunar", nil), ("Terminal", nil),
         ("Mousepad", nil)],
        [("Chromium", CGSize(width: 900, height: 600)), ("File System - Thunar", nil), ("Terminal", nil),
         ("Mousepad", nil), ("GIMP", CGSize(width: 1600, height: 1000)), ("Settings", CGSize(width: 660, height: 480))],
    ]

    private func windows(_ set: [(title: String, minimum: CGSize?)]) -> [Int: RemoteWindow] {
        var windows: [Int: RemoteWindow] = [:]
        for (index, entry) in set.enumerated() {
            let window = RemoteWindow(id: index + 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), overrideRedirect: false)
            window.title = entry.title
            window.minimumSize = entry.minimum
            window.raisedAt = Date(timeIntervalSince1970: TimeInterval(index))
            windows[window.id] = window
        }
        return windows
    }

    private var thisScreen: (name: String, size: CGSize)? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let size = scene.screen.bounds.size
        let inset = scene.windows.first?.safeAreaInsets ?? .zero
        let area = DesktopChrome.workspaceSize(in: CGSize(width: size.width, height: size.height - inset.top),
                                               dockHeight: YardDock.height, bottomInset: inset.bottom)
        return ("this-simulator", area)
    }

    func testTheAppsYardObeysTheTilePolicyOnEveryScreen() throws {
        let shots = ProcessInfo.processInfo.environment["CABOOSE_LAYOUT_SHOTS"].map(URL.init(fileURLWithPath:))
        if let shots { try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        for screen in Self.screens + (thisScreen.map { [$0] } ?? []) {
            for set in Self.sets {
                let yard = YardModel()
                yard.resize(to: screen.size)
                let windows = windows(set)
                // Windows arrive one at a time, as the computer announces them.
                for count in 1...set.count {
                    yard.sync(windows.filter { $0.key <= count }) { _ in nil }
                }
                let context = "\(screen.name) with \(set.count) windows"
                let frames = yard.layout.frames(in: yard.metrics)
                XCTAssertEqual(Set(frames.keys), Set(windows.keys), context)
                for (id, frame) in frames {
                    XCTAssertTrue(TilePolicy.allows(frame.size, required: yard.metrics.required(id), in: yard.metrics.area),
                                  "\(context): \(windows[id]!.title) is \(frame.size)")
                }
                // On its side and back: the same tiles.
                yard.resize(to: CGSize(width: screen.size.height, height: screen.size.width))
                yard.resize(to: screen.size)
                XCTAssertEqual(yard.layout.frames(in: yard.metrics), frames, "\(context): turning and back moved a tile")
                if let shots {
                    let screens = max(1, Int((yard.layout.trackWidth(in: yard.metrics) / (yard.metrics.size.width + yard.metrics.gap)).rounded(.up)))
                    let image = draw(frames, titles: windows.mapValues(\.title), screen: yard.metrics.size, gap: yard.metrics.gap,
                                     screens: screens, corner: yard.metrics.cornerRadius, bar: yard.metrics.titleBar.height)
                    try XCTUnwrap(image.pngData()).write(to: shots.appendingPathComponent("\(screen.name)-\(set.count).png"))
                }
            }
        }
    }

    /// The owner's case on the floating desktop: Chromium (a large minimum) and a file
    /// browser, the file browser snapped to the left half. Snap assist puts Chromium in the
    /// right half at once; the two meet exactly, and their shared divider resizes both
    /// within what each needs.
    func testSnappedWindowsShareAnEdgeAndADivider() throws {
        let shots = ProcessInfo.processInfo.environment["CABOOSE_LAYOUT_SHOTS"].map(URL.init(fileURLWithPath:))
        if let shots { try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true) }
        let area = CGRect(x: 0, y: 0, width: 1194, height: 760)
        let need: (Int?) -> CGSize = { id in
            TilePolicy.required(minimum: id == 1 ? CGSize(width: 500, height: 400) : nil, titleBar: 32, in: area.size)
        }
        let accepts: (Int, FreeDesktopLayout.Snap) -> Bool = { id, snap in
            TilePolicy.allows(FreeDesktopLayout.rect(for: snap, in: area).size, required: need(id), in: area.size)
        }
        let plan = SnapAssist.plan(2, snap: .left, layout: [.left, .right], others: [1], accepts: accepts)
        XCTAssertEqual(plan.assigned, [.left: 2, .right: 1])
        var group = try XCTUnwrap(SnapGroup(layout: [.left, .right], assigned: plan.assigned))
        let titles = [1: "Chromium", 2: "File System - Thunar"]
        var frames = group.frames(in: area)
        XCTAssertEqual(frames[2]!.maxX, frames[1]!.minX)
        XCTAssertEqual(frames[1]!.maxX, area.maxX)
        let divider = try XCTUnwrap(group.dividers(in: area, thickness: 10).first)
        group.drag(divider.divider, to: 2000, in: area, required: need)
        frames = group.frames(in: area)
        XCTAssertEqual(frames[1]!.width, need(1).width, accuracy: 0.5)
        XCTAssertEqual(frames[2]!.maxX, frames[1]!.minX)
        if let shots {
            for (name, layout) in [("snap-assist-halves", SnapGroup(layout: [.left, .right], assigned: plan.assigned)!),
                                   ("snap-divider-dragged", group)] {
                let image = draw(layout.frames(in: area), titles: titles, screen: area.size, gap: 0, screens: 1, corner: 10, bar: 32)
                try XCTUnwrap(image.pngData()).write(to: shots.appendingPathComponent("\(name).png"))
            }
        }
        // Switchyard on an iPad: more windows than the other half holds, so assist offers them.
        let yard = YardModel()
        yard.resize(to: CGSize(width: 1376, height: 940))
        let windows = self.windows([("File System - Thunar", nil), ("Chromium", CGSize(width: 1000, height: 800)), ("Terminal", nil)])
        for count in 1...3 { yard.sync(windows.filter { $0.key <= count }) { _ in nil } }
        let offered = yard.layout.snapAssist(1, to: .left, layout: [.left, .right], in: yard.metrics)
        XCTAssertEqual(offered.open, [.right])
        XCTAssertEqual(Set(offered.choices), [2, 3])
    }

    /// The track as the person would scroll along it: each screen in turn, each tile with
    /// its title bar and title.
    private func draw(_ frames: [Int: CGRect], titles: [Int: String], screen: CGSize, gap: CGFloat, screens: Int,
                      corner: CGFloat, bar barHeight: CGFloat) -> UIImage {
        let metrics = (size: screen, gap: gap, cornerRadius: corner)
        let stride = metrics.size.width + 24
        let size = CGSize(width: CGFloat(screens) * stride + 24, height: metrics.size.height + 48)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.08, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let label: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13, weight: .medium),
                                                        .foregroundColor: UIColor(white: 0.6, alpha: 1)]
            for screen in 0..<screens {
                let origin = CGPoint(x: 24 + CGFloat(screen) * stride, y: 36)
                let rect = CGRect(origin: origin, size: metrics.size)
                UIColor(red: 0.16, green: 0.2, blue: 0.24, alpha: 1).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 14).fill()
                ("Screen \(screen + 1) · \(Int(metrics.size.width)) × \(Int(metrics.size.height)) pt" as NSString)
                    .draw(at: CGPoint(x: origin.x, y: 12), withAttributes: label)
                context.cgContext.saveGState()
                UIBezierPath(roundedRect: rect, cornerRadius: 14).addClip()
                for (id, frame) in frames {
                    let shown = frame.offsetBy(dx: origin.x - CGFloat(screen) * (metrics.size.width + metrics.gap), dy: origin.y)
                    guard shown.intersects(rect) else { continue }
                    let tile = UIBezierPath(roundedRect: shown, cornerRadius: metrics.cornerRadius)
                    UIColor(white: 0.18, alpha: 1).setFill()
                    tile.fill()
                    let bar = CGRect(x: shown.minX, y: shown.minY, width: shown.width, height: barHeight)
                    context.cgContext.saveGState()
                    tile.addClip()
                    UIColor(white: 0.25, alpha: 1).setFill()
                    context.fill(bar)
                    context.cgContext.restoreGState()
                    for (index, color) in [UIColor.systemRed, UIColor.systemGreen].enumerated() {
                        color.setFill()
                        UIBezierPath(ovalIn: CGRect(x: shown.minX + 12 + CGFloat(index) * 22, y: bar.midY - 7, width: 14, height: 14)).fill()
                    }
                    let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 14, weight: .semibold),
                                                                .foregroundColor: UIColor.white]
                    ((titles[id] ?? "") as NSString).draw(at: CGPoint(x: shown.minX + 62, y: bar.midY - 9), withAttributes: title)
                    let detail = "\(Int(frame.width)) × \(Int(frame.height)) pt"
                    (detail as NSString).draw(at: CGPoint(x: shown.minX + 14, y: bar.maxY + 10), withAttributes: label)
                    UIColor(white: 0.35, alpha: 1).setStroke()
                    tile.lineWidth = 1
                    tile.stroke()
                }
                context.cgContext.restoreGState()
            }
        }
    }
}
