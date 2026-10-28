import CabooseKit
import Observation
import SwiftUI

/// The big-screen desktop: what is on a TV or monitor when the phone becomes its trackpad.
///
/// Linux windows keep the server's geometry (in Linux pixels); the desktop draws them at
/// `frame / pixelsPerPoint` with a native title bar above each one, a dock, and a cursor.
/// Every pointer action is hit-tested here, in desktop points, so the phone's trackpad,
/// a mouse, or touch on an iPad all reach the same windows the same way.
@MainActor @Observable
final class DesktopModel {
    enum Hit: Equatable {
        case none
        case dock(String)
        case titleBar(Int)
        case close(Int)
        case minimize(Int)
        case zoom(Int)
        case launchpadButton
        case launcher(String)
        case content(Int, CGPoint)  // window id, point in window pixels
        case resize(Int)
    }

    /// How much larger than a Mac at arm's length the desktop draws, for the distance it is
    /// seen from: title bars, the dock, the cursor and (through the DPI it asks Linux for)
    /// the apps' own text all grow by it, so a 4K TV across a room reads like a laptop.
    var ui: CGFloat = 1
    var titleBarHeight: CGFloat { 30 * ui }
    var dockHeight: CGFloat { 76 * ui }
    var dockBottomInset: CGFloat { 10 * ui }
    var maximizedFrame: CGRect {
        let area = DesktopGeometry.maximizedFrame(size: size, titleBarHeight: titleBarHeight,
                                                 dockHeight: dockHeight, dockBottomInset: dockBottomInset, dockGap: 8 * ui)
        return CGRect(x: area.minX * pixelsPerPoint, y: area.minY * pixelsPerPoint,
                      width: area.width * pixelsPerPoint, height: area.height * pixelsPerPoint).integral
    }

    /// The size factor for a display this many points wide: a 1600-point-wide desktop reads
    /// well across a room, so wider ones scale up to match.
    static func automaticUI(forWidth width: CGFloat) -> CGFloat { max(1, width / 1600) }

    /// On the phone's or iPad's own screen, held at arm's length: a little smaller than a Mac
    /// on a phone, a Mac's size on an iPad.
    static func deviceUI(forWidth width: CGFloat) -> CGFloat { min(1, max(0.72, width / 1100)) }

    /// Fingers on the glass point straight at things; the arrow shows only for a pointer
    /// (an iPad's mouse or trackpad), not under a finger.
    var directTouch = false
    var pointerHovering = false
    var showsCursor: Bool { !directTouch || pointerHovering }

    let pixelsPerPoint: CGFloat
    var size: CGSize = .zero
    var cursor = CGPoint(x: 400, y: 300)
    var hovered: Hit = .none
    /// Back-to-front stacking order of window ids.
    private(set) var stacking: [Int] = []
    private(set) var minimized = Set<Int>()
    var dockFrames: [String: CGRect] = [:]
    var contextDockID: String?
    /// Launchpad: every app, in a grid over the desktop.
    var launchpadOpen = false
    var launchpadButtonFrame: CGRect = .null
    var launcherFrames: [String: CGRect] = [:]

    private var drag: (hit: Hit, start: CGPoint, frame: CGRect)?

    init(pixelsPerPoint: CGFloat) { self.pixelsPerPoint = pixelsPerPoint }

    func sync(with windows: [RemoteWindow]) {
        let ids = Set(windows.map(\.id))
        stacking.removeAll { !ids.contains($0) }
        unzoomedFrames = unzoomedFrames.filter { ids.contains($0.key) }
        for window in windows.sorted(by: { $0.id < $1.id }) where !stacking.contains(window.id) { stacking.append(window.id) }
        minimized.formIntersection(ids)
    }

    func raise(_ id: Int) {
        stacking.removeAll { $0 == id }
        stacking.append(id)
        minimized.remove(id)
    }

    func minimize(_ id: Int) { minimized.insert(id) }

    func isVisible(_ id: Int) -> Bool { !minimized.contains(id) }

    /// The window's content rect in desktop points.
    func contentRect(_ window: RemoteWindow) -> CGRect {
        if window.isFullscreen { return CGRect(origin: .zero, size: size) }
        return CGRect(x: window.frame.minX / pixelsPerPoint, y: window.frame.minY / pixelsPerPoint + (window.isAuxiliary ? 0 : titleBarHeight),
               width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
    }

    func chromeRect(_ window: RemoteWindow) -> CGRect {
        let content = contentRect(window)
        return window.isAuxiliary || window.isFullscreen ? content : content.inset(by: UIEdgeInsets(top: -titleBarHeight, left: 0, bottom: 0, right: 0))
    }

    /// The frontmost window that covers the whole screen, if any: it hides the dock.
    func fullscreenWindow(in windows: [Int: RemoteWindow]) -> RemoteWindow? {
        stacking.reversed().lazy.filter { self.isVisible($0) }.compactMap { windows[$0] }.first { !$0.isAuxiliary }
            .flatMap { $0.isFullscreen ? $0 : nil }
    }

    func hitTest(_ point: CGPoint, windows: [Int: RemoteWindow]) -> Hit {
        if fullscreenWindow(in: windows) == nil {
            if launchpadButtonFrame.contains(point) { return .launchpadButton }
            for (id, frame) in dockFrames where frame.contains(point) { return .dock(id) }
        }
        if launchpadOpen {
            for (id, frame) in launcherFrames where frame.contains(point) { return .launcher(id) }
            return .none
        }
        for id in stacking.reversed() where isVisible(id) {
            guard let window = windows[id] else { continue }
            let chrome = chromeRect(window)
            guard chrome.contains(point) else { continue }
            let content = contentRect(window)
            if content.contains(point) {
                if !window.isAuxiliary, point.x > content.maxX - 18 * ui, point.y > content.maxY - 18 * ui { return .resize(id) }
                let local = CGPoint(x: (point.x - content.minX) * pixelsPerPoint, y: (point.y - content.minY) * pixelsPerPoint)
                return .content(id, local)
            }
            // The traffic lights as DesktopWindow draws them: 12-point circles 8 apart after a
            // 12-point inset, all scaled by `ui`; each takes half the gap on either side.
            let x = (point.x - chrome.minX) / ui
            if x < 28 { return .close(id) }
            if x < 48 { return .minimize(id) }
            if x < 68 { return .zoom(id) }
            return .titleBar(id)
        }
        return .none
    }

    // MARK: Pointer

    func move(by delta: CGPoint, session: (any DisplaySession)?) {
        cursor = CGPoint(x: min(max(0, cursor.x + delta.x), size.width), y: min(max(0, cursor.y + delta.y), size.height))
        guard let session else { return }
        if let drag {
            dragMoved(drag, session: session)
            return
        }
        hovered = hitTest(cursor, windows: session.windows)
        if case .content(let id, let local) = hovered, let window = session.windows[id] {
            session.pointerMove(in: window, to: local)
        }
    }

    func click(button: Int = 1, session: (any DisplaySession)?, open: (String) -> Void) {
        guard let session else { return }
        let hit = hitTest(cursor, windows: session.windows)
        if launchpadOpen, hit != .launchpadButton {
            launchpadOpen = false
            if case .launcher(let id) = hit { open(id) }
            return
        }
        switch hit {
        case .launchpadButton: launchpadOpen.toggle()
        case .launcher(let id): open(id)
        case .dock(let id):
            if button == 3 { contextDockID = id } else { contextDockID = nil; open(id) }
        case .close(let id): if let window = session.windows[id] { session.close(window) }
        case .minimize(let id): minimize(id)
        case .zoom(let id): toggleZoom(id, session)
        case .titleBar(let id), .resize(let id): raise(id); focus(id, session)
        case .content(let id, let local):
            guard let window = session.windows[id] else { return }
            if !window.isAuxiliary { raise(id) }
            focus(id, session)
            session.pointerMove(in: window, to: local)
            session.pointerButton(in: window, button: button, pressed: true, at: local)
            session.pointerButton(in: window, button: button, pressed: false, at: local)
        case .none:
            break
        }
    }

    func beginDrag(session: (any DisplaySession)?) {
        guard let session else { return }
        let hit = hitTest(cursor, windows: session.windows)
        switch hit {
        case .titleBar(let id), .resize(let id):
            guard let window = session.windows[id] else { return }
            raise(id)
            drag = (hit, cursor, window.frame)
        case .content(let id, let local):
            guard let window = session.windows[id] else { return }
            raise(id)
            focus(id, session)
            session.pointerButton(in: window, button: 1, pressed: true, at: local)
            drag = (hit, cursor, window.frame)
        default:
            break
        }
    }

    func endDrag(session: (any DisplaySession)?) {
        defer { drag = nil }
        guard let drag, let session else { return }
        if case .content(let id, _) = drag.hit, let window = session.windows[id] {
            let content = contentRect(window)
            let local = CGPoint(x: (cursor.x - content.minX) * pixelsPerPoint, y: (cursor.y - content.minY) * pixelsPerPoint)
            session.pointerButton(in: window, button: 1, pressed: false, at: local)
        }
    }

    func scroll(by delta: CGPoint, session: (any DisplaySession)?) {
        guard let session, case .content(let id, let local) = hitTest(cursor, windows: session.windows),
              let window = session.windows[id] else { return }
        session.scroll(in: window, dx: delta.x * pixelsPerPoint, dy: delta.y * pixelsPerPoint, at: local)
    }

    private func dragMoved(_ drag: (hit: Hit, start: CGPoint, frame: CGRect), session: any DisplaySession) {
        let dx = (cursor.x - drag.start.x) * pixelsPerPoint, dy = (cursor.y - drag.start.y) * pixelsPerPoint
        switch drag.hit {
        case .titleBar(let id):
            guard let window = session.windows[id] else { return }
            unzoomedFrames.removeValue(forKey: id)
            session.configure(window, frame: CGRect(x: drag.frame.minX + dx, y: max(0, drag.frame.minY + dy),
                                                    width: drag.frame.width, height: drag.frame.height), state: ["maximized": false])
        case .resize(let id):
            guard let window = session.windows[id] else { return }
            unzoomedFrames.removeValue(forKey: id)
            let minimum = window.minimumSize ?? CGSize(width: 240, height: 160)
            session.configure(window, frame: CGRect(x: drag.frame.minX, y: drag.frame.minY,
                                                    width: max(minimum.width, drag.frame.width + dx),
                                                    height: max(minimum.height, drag.frame.height + dy)), state: ["maximized": false])
        case .content(let id, _):
            guard let window = session.windows[id] else { return }
            let content = contentRect(window)
            session.pointerMove(in: window, to: CGPoint(x: (cursor.x - content.minX) * pixelsPerPoint,
                                                        y: (cursor.y - content.minY) * pixelsPerPoint))
        default:
            break
        }
    }

    private func focus(_ id: Int, _ session: any DisplaySession) {
        session.focus(session.windows[id])
    }

    /// The second click of a double-click. In a window it is the app's own double-click (the
    /// first already reached it); on a title bar it zooms, as on a Mac; elsewhere it repeats.
    func doubleClick(session: (any DisplaySession)?, open: (String) -> Void) {
        guard let session else { return }
        switch hitTest(cursor, windows: session.windows) {
        case .titleBar(let id): toggleZoom(id, session)
        case .content: click(session: session, open: open)
        default: break
        }
    }

    /// Frames windows had before they went full screen, to restore them.
    private var windowedFrames: [Int: CGRect] = [:]

    /// Follows the app's own full-screen request: the window takes the whole display (in
    /// Linux pixels) and gets its old frame back when it leaves.
    func applyFullscreen(_ window: RemoteWindow, session: (any DisplaySession)?) {
        guard let session else { return }
        if window.isFullscreen {
            if windowedFrames[window.id] == nil { windowedFrames[window.id] = window.frame }
            let full = CGRect(x: 0, y: 0, width: size.width * pixelsPerPoint, height: size.height * pixelsPerPoint).integral
            raise(window.id)
            if window.frame != full { session.configure(window, frame: full) }
        } else if let previous = windowedFrames.removeValue(forKey: window.id) {
            session.configure(window, frame: previous, state: ["maximized": false])
        }
    }

    /// Frames windows had before they were zoomed, to restore them.
    private var unzoomedFrames: [Int: CGRect] = [:]

    func isZoomed(_ window: Int) -> Bool { unzoomedFrames[window] != nil }

    /// The green button: fill the desktop above the dock, or go back to where it was.
    func toggleZoom(_ id: Int, _ session: any DisplaySession) {
        guard let window = session.windows[id] else { return }
        raise(id)
        focus(id, session)
        if let previous = unzoomedFrames.removeValue(forKey: id) {
            session.configure(window, frame: previous, state: ["maximized": false])
            return
        }
        unzoomedFrames[id] = window.frame
        session.configure(window, frame: maximizedFrame, state: ["maximized": false])
    }

    /// Rotation, toolbar changes and display scaling keep zoomed windows above the dock.
    func resizeMaximizedWindows(session: (any DisplaySession)?) {
        guard let session else { return }
        for id in unzoomedFrames.keys {
            guard let window = session.windows[id], !window.isFullscreen else { continue }
            if window.frame != maximizedFrame { session.configure(window, frame: maximizedFrame, state: ["maximized": false]) }
        }
    }

    /// The dock icon of an app with windows: bring back what was minimized, else bring its
    /// latest window forward. Returns false when the app has no windows and should launch.
    func reveal(_ windowIDs: [Int], session: (any DisplaySession)?) -> Bool {
        guard let session, !windowIDs.isEmpty else { return false }
        let hidden = windowIDs.filter { minimized.contains($0) }
        for id in hidden { raise(id) }
        let front = (hidden.isEmpty ? windowIDs : hidden).max { (stacking.firstIndex(of: $0) ?? -1) < (stacking.firstIndex(of: $1) ?? -1) }
        if let front {
            raise(front)
            focus(front, session)
        }
        return true
    }

    /// Where a dialog or tool window opens: centred over its parent's content, or on the
    /// desktop, kept clear of the top edge and the dock.
    func centred(_ window: RemoteWindow, over parent: RemoteWindow?) -> CGRect {
        let usable = CGRect(x: 0, y: titleBarHeight, width: size.width, height: max(100, size.height - dockHeight - titleBarHeight))
        let width = min(window.frame.width / pixelsPerPoint, usable.width * 0.9)
        let height = min(window.frame.height / pixelsPerPoint, usable.height * 0.9)
        let around = parent.map { contentRect($0) } ?? usable
        var origin = CGPoint(x: around.midX - width / 2, y: around.midY - height / 2)
        origin.x = min(max(usable.minX, origin.x), usable.maxX - width)
        origin.y = min(max(usable.minY, origin.y), usable.maxY - height)
        return CGRect(x: origin.x * pixelsPerPoint, y: origin.y * pixelsPerPoint,
                      width: width * pixelsPerPoint, height: height * pixelsPerPoint).integral
    }

    /// Each window's place when the desktop last went down, in Linux pixels.
    private var rememberedFrames: [Int: CGRect] = [:]

    /// Keeps the windows' places for when this desktop comes back.
    func remember(_ windows: [RemoteWindow]) {
        rememberedFrames = Dictionary(windows.filter { !$0.isOverrideRedirect }.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }

    /// A window's remembered place, once, if it still fits on the desktop.
    func remembered(_ window: RemoteWindow) -> CGRect? {
        guard let frame = rememberedFrames.removeValue(forKey: window.id) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: size.width * pixelsPerPoint, height: size.height * pixelsPerPoint)
        return bounds.contains(frame) ? frame : nil
    }

    /// A good first place for a new window: centred, cascading, clear of the dock.
    func placement(for window: RemoteWindow, index: Int) -> CGRect {
        let usable = CGSize(width: size.width, height: size.height - dockHeight - titleBarHeight)
        let width = min(window.frame.width / pixelsPerPoint, usable.width * 0.8)
        let height = min(window.frame.height / pixelsPerPoint, usable.height * 0.85)
        let offset = CGFloat(index % 6) * 28 * ui
        var origin = CGPoint(x: (size.width - width) / 2 - 84 * ui + offset, y: titleBarHeight + 40 * ui + offset)
        // A narrow desktop (a phone held upright beside its bar) keeps the window on screen.
        origin.x = min(max(0, origin.x), max(0, size.width - width))
        return CGRect(x: origin.x * pixelsPerPoint, y: origin.y * pixelsPerPoint,
                      width: width * pixelsPerPoint, height: height * pixelsPerPoint).integral
    }
}
