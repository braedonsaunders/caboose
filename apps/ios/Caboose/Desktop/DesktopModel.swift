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
        case content(Int, CGPoint)  // window id, point in window pixels
        case resize(Int)
    }

    /// How much larger than a Mac at arm's length the desktop draws, for the distance it is
    /// seen from: title bars, the dock, the cursor and (through the DPI it asks Linux for)
    /// the apps' own text all grow by it, so a 4K TV across a room reads like a laptop.
    var ui: CGFloat = 1
    var titleBarHeight: CGFloat { 30 * ui }
    var dockHeight: CGFloat { 76 * ui }

    /// The size factor for a display this many points wide: a 1600-point-wide desktop reads
    /// well across a room, so wider ones scale up to match.
    static func automaticUI(forWidth width: CGFloat) -> CGFloat { max(1, width / 1600) }

    let pixelsPerPoint: CGFloat
    var size: CGSize = .zero
    var cursor = CGPoint(x: 400, y: 300)
    var hovered: Hit = .none
    /// Back-to-front stacking order of window ids.
    private(set) var stacking: [Int] = []
    private(set) var minimized = Set<Int>()
    var dockFrames: [String: CGRect] = [:]

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
        CGRect(x: window.frame.minX / pixelsPerPoint, y: window.frame.minY / pixelsPerPoint + (window.isAuxiliary ? 0 : titleBarHeight),
               width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
    }

    func chromeRect(_ window: RemoteWindow) -> CGRect {
        let content = contentRect(window)
        return window.isAuxiliary ? content : content.inset(by: UIEdgeInsets(top: -titleBarHeight, left: 0, bottom: 0, right: 0))
    }

    func hitTest(_ point: CGPoint, windows: [Int: RemoteWindow]) -> Hit {
        for (id, frame) in dockFrames where frame.contains(point) { return .dock(id) }
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

    func move(by delta: CGPoint, session: XpraSession?) {
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

    func click(button: Int = 1, session: XpraSession?, open: (String) -> Void) {
        guard let session else { return }
        let hit = hitTest(cursor, windows: session.windows)
        switch hit {
        case .dock(let id): open(id)
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

    func beginDrag(session: XpraSession?) {
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

    func endDrag(session: XpraSession?) {
        defer { drag = nil }
        guard let drag, let session else { return }
        if case .content(let id, _) = drag.hit, let window = session.windows[id] {
            let content = contentRect(window)
            let local = CGPoint(x: (cursor.x - content.minX) * pixelsPerPoint, y: (cursor.y - content.minY) * pixelsPerPoint)
            session.pointerButton(in: window, button: 1, pressed: false, at: local)
        }
    }

    func scroll(by delta: CGPoint, session: XpraSession?) {
        guard let session, case .content(let id, let local) = hitTest(cursor, windows: session.windows),
              let window = session.windows[id] else { return }
        session.scroll(in: window, dx: delta.x * pixelsPerPoint, dy: delta.y * pixelsPerPoint, at: local)
    }

    private func dragMoved(_ drag: (hit: Hit, start: CGPoint, frame: CGRect), session: XpraSession) {
        let dx = (cursor.x - drag.start.x) * pixelsPerPoint, dy = (cursor.y - drag.start.y) * pixelsPerPoint
        switch drag.hit {
        case .titleBar(let id):
            guard let window = session.windows[id] else { return }
            let top = titleBarHeight * pixelsPerPoint
            session.configure(window, frame: CGRect(x: drag.frame.minX + dx, y: max(top, drag.frame.minY + dy),
                                                    width: drag.frame.width, height: drag.frame.height))
        case .resize(let id):
            guard let window = session.windows[id] else { return }
            let minimum = window.minimumSize ?? CGSize(width: 240, height: 160)
            session.configure(window, frame: CGRect(x: drag.frame.minX, y: drag.frame.minY,
                                                    width: max(minimum.width, drag.frame.width + dx),
                                                    height: max(minimum.height, drag.frame.height + dy)))
        case .content(let id, _):
            guard let window = session.windows[id] else { return }
            let content = contentRect(window)
            session.pointerMove(in: window, to: CGPoint(x: (cursor.x - content.minX) * pixelsPerPoint,
                                                        y: (cursor.y - content.minY) * pixelsPerPoint))
        default:
            break
        }
    }

    private func focus(_ id: Int, _ session: XpraSession) {
        session.focus(session.windows[id])
    }

    /// The second click of a double-click. In a window it is the app's own double-click (the
    /// first already reached it); on a title bar it zooms, as on a Mac; elsewhere it repeats.
    func doubleClick(session: XpraSession?, open: (String) -> Void) {
        guard let session else { return }
        switch hitTest(cursor, windows: session.windows) {
        case .titleBar(let id): toggleZoom(id, session)
        case .content: break
        default: click(session: session, open: open)
        }
    }

    /// Frames windows had before they were zoomed, to restore them.
    private var unzoomedFrames: [Int: CGRect] = [:]

    /// The green button: fill the desktop above the dock, or go back to where it was.
    func toggleZoom(_ id: Int, _ session: XpraSession) {
        guard let window = session.windows[id] else { return }
        raise(id)
        focus(id, session)
        if let previous = unzoomedFrames.removeValue(forKey: id) {
            session.configure(window, frame: previous)
            return
        }
        unzoomedFrames[id] = window.frame
        let margin = 8 * ui
        let top = margin + titleBarHeight
        let bottom = size.height - dockHeight - 10 * ui - margin
        let area = CGRect(x: margin, y: top, width: size.width - 2 * margin, height: max(200, bottom - top))
        session.configure(window, frame: CGRect(x: area.minX * pixelsPerPoint, y: area.minY * pixelsPerPoint,
                                                width: area.width * pixelsPerPoint, height: area.height * pixelsPerPoint).integral)
    }

    /// The dock icon of an app with windows: bring back what was minimized, else bring its
    /// latest window forward. Returns false when the app has no windows and should launch.
    func reveal(_ windowIDs: [Int], session: XpraSession?) -> Bool {
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

    /// A good first place for a new window: centred, cascading, clear of the dock.
    func placement(for window: RemoteWindow, index: Int) -> CGRect {
        let usable = CGSize(width: size.width, height: size.height - dockHeight - titleBarHeight)
        let width = min(window.frame.width / pixelsPerPoint, usable.width * 0.8)
        let height = min(window.frame.height / pixelsPerPoint, usable.height * 0.85)
        let offset = CGFloat(index % 6) * 28 * ui
        let origin = CGPoint(x: (size.width - width) / 2 - 84 * ui + offset, y: titleBarHeight + 40 * ui + offset)
        return CGRect(x: origin.x * pixelsPerPoint, y: origin.y * pixelsPerPoint,
                      width: width * pixelsPerPoint, height: height * pixelsPerPoint).integral
    }
}
