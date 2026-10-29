import CabooseKit
import Observation
import SwiftUI

/// The big-screen desktop: what is on a TV or monitor when the phone becomes its trackpad.
///
/// Linux windows keep the server's geometry (in Linux pixels); the desktop draws them at
/// `frame / pixelsPerPoint` with a native title bar above each one, a dock, and a cursor.
/// Where each window goes is its place in `FreeDesktopLayout`, kept for the computer: the
/// frame the owner gave it, or a snap, fitted to whatever size the desktop is now.
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
        case launcherPage(Int)
        case content(Int, CGPoint)  // window id, point in window pixels
        case resize(Int)
    }

    /// How much larger than a Mac at arm's length the desktop draws, for the distance it is
    /// seen from: title bars, the dock, the cursor and (through the DPI it asks Linux for)
    /// the apps' own text all grow by it, so a 4K TV across a room reads like a laptop.
    var ui: CGFloat = 1
    /// Every window's title bar: its controls' places for drawing and for hit-testing.
    var titleBar: WindowTitleBar { WindowTitleBar(ui: ui, touch: directTouch) }
    var titleBarHeight: CGFloat { titleBar.height }
    var dockHeight: CGFloat { 76 * ui }
    var dockBottomInset: CGFloat { 10 * ui }
    var maximizedFrame: CGRect {
        let area = DesktopGeometry.maximizedFrame(size: size, titleBarHeight: titleBarHeight,
                                                 dockHeight: dockHeight, dockBottomInset: dockBottomInset, dockGap: 8 * ui)
        return CGRect(x: area.minX * pixelsPerPoint, y: area.minY * pixelsPerPoint,
                      width: area.width * pixelsPerPoint, height: area.height * pixelsPerPoint).integral
    }

    /// Where windows go: the desktop above the dock, in points. A window's whole frame,
    /// title bar included, stays inside it.
    var workArea: CGRect {
        CGRect(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height - dockHeight - dockBottomInset - 8 * ui))
    }

    /// The owner's places for the windows, kept for the computer between launches.
    private(set) var layout = FreeDesktopLayout()
    /// Saves the places for the computer and screen they belong to.
    var storageKey: String? {
        didSet {
            guard storageKey != oldValue else { return }
            layout = FreeDesktopLayout.decoded(from: storageKey.flatMap { UserDefaults.standard.data(forKey: $0) })
        }
    }

    private func save() {
        guard let storageKey, let data = layout.encoded() else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Where a dragged title bar would snap the window if let go now, in desktop points.
    private(set) var snapPreview: CGRect?
    private var pendingSnap: FreeDesktopLayout.Snap?

    /// A window's whole frame (title bar and content) in desktop points, as Linux pixels.
    func linuxFrame(_ chrome: CGRect) -> CGRect {
        CGRect(x: chrome.minX * pixelsPerPoint, y: chrome.minY * pixelsPerPoint,
               width: chrome.width * pixelsPerPoint, height: max(1, chrome.height - titleBarHeight) * pixelsPerPoint).integral
    }

    /// The smallest whole frame the window accepts, in desktop points.
    func minimumChrome(_ window: RemoteWindow) -> CGSize {
        let minimum = window.minimumSize ?? .zero
        return CGSize(width: minimum.width / pixelsPerPoint, height: minimum.height / pixelsPerPoint + titleBarHeight)
    }

    private func app(_ window: RemoteWindow) -> String? { window.appClass?.name }

    /// Where the window belongs on this desktop by its place, in Linux pixels, if it has one.
    func placedFrame(_ window: RemoteWindow) -> CGRect? {
        layout.frame(for: window.id, app: app(window), in: workArea, minimum: minimumChrome(window)).map(linuxFrame)
    }

    /// A window that has no place yet gets its first one, and keeps it.
    func place(_ window: RemoteWindow, index: Int) -> CGRect {
        if let frame = placedFrame(window) { return frame }
        let frame = placement(for: window, index: index)
        layout.setPreferred(window.id, frame: chromeRect(frame: frame), in: workArea, app: app(window))
        save()
        return frame
    }

    /// The whole frame, in desktop points, of a window at `frame` Linux pixels.
    private func chromeRect(frame: CGRect) -> CGRect {
        CGRect(x: frame.minX / pixelsPerPoint, y: frame.minY / pixelsPerPoint,
               width: frame.width / pixelsPerPoint, height: frame.height / pixelsPerPoint + titleBarHeight)
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
    var launcherPage = 0
    var launcherPageFrames: [Int: CGRect] = [:]

    /// A press being dragged: what it started on, where the pointer and the window's whole
    /// frame (in points) were when it started, or when it last left a snap.
    private var drag: (hit: Hit, start: CGPoint, chrome: CGRect)?

    init(pixelsPerPoint: CGFloat) { self.pixelsPerPoint = pixelsPerPoint }

    /// The windows a ready session last showed, to tell a closed window from a reconnect.
    private var liveWindows: (session: ObjectIdentifier, ids: Set<Int>)?

    /// Follows the computer's windows. A window's place is forgotten when it closes: when it
    /// leaves a session that is still ready. A dropped or replaced connection forgets nothing,
    /// since window ids survive reconnects and parking.
    func sync(with windows: [RemoteWindow], session: (any DisplaySession)? = nil) {
        let ids = Set(windows.map(\.id))
        stacking.removeAll { !ids.contains($0) }
        for window in windows.sorted(by: { $0.id < $1.id }) where !stacking.contains(window.id) { stacking.append(window.id) }
        minimized.formIntersection(ids)
        guard let session, case .ready = session.state else { return }
        let identity = ObjectIdentifier(session)
        if let live = liveWindows, live.session == identity {
            let closed = live.ids.subtracting(ids)
            for id in closed { layout.remove(id) }
            if !closed.isEmpty { save() }
        }
        liveWindows = (identity, ids)
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
            for (direction, frame) in launcherPageFrames where frame.contains(point) { return .launcherPage(direction) }
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
            // The controls answer where DesktopWindow draws them, across the bar's height.
            switch titleBar.control(at: CGPoint(x: point.x - chrome.minX, y: point.y - chrome.minY)) {
            case .close: return .close(id)
            case .minimize: return .minimize(id)
            case .zoom: return .zoom(id)
            case nil: return .titleBar(id)
            }
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
        if case .launcherPage(let direction) = hit {
            launcherFrames = [:]
            launcherPageFrames = [:]
            launcherPage = max(0, launcherPage + direction)
            return
        }
        if launchpadOpen, hit != .launchpadButton {
            launchpadOpen = false
            if case .launcher(let id) = hit { open(id) }
            return
        }
        switch hit {
        case .launchpadButton: launchpadOpen.toggle()
        case .launcher(let id): open(id)
        case .launcherPage: break
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
            drag = (hit, cursor, chromeRect(window))
        case .content(let id, let local):
            guard let window = session.windows[id] else { return }
            raise(id)
            focus(id, session)
            session.pointerButton(in: window, button: 1, pressed: true, at: local)
            drag = (hit, cursor, chromeRect(window))
        default:
            break
        }
    }

    func endDrag(session: (any DisplaySession)?) {
        defer { drag = nil; snapPreview = nil; pendingSnap = nil; dragged = nil }
        guard let drag, let session else { return }
        switch drag.hit {
        case .content(let id, _):
            guard let window = session.windows[id] else { return }
            let content = contentRect(window)
            let local = CGPoint(x: (cursor.x - content.minX) * pixelsPerPoint, y: (cursor.y - content.minY) * pixelsPerPoint)
            session.pointerButton(in: window, button: 1, pressed: false, at: local)
        case .titleBar(let id), .resize(let id):
            guard let window = session.windows[id], let frame = dragged else { return }
            // Where it was let go is where it returns to from a snap.
            layout.setPreferred(id, frame: frame, in: workArea, app: app(window))
            if let snap = pendingSnap {
                layout.setSnap(id, snap, current: frame, in: workArea, app: app(window))
                applyPlace(window, session)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            save()
        default:
            break
        }
    }

    /// The whole frame a title bar or corner drag has put the window at, in points.
    private var dragged: CGRect?

    func scroll(by delta: CGPoint, session: (any DisplaySession)?) {
        guard let session, case .content(let id, let local) = hitTest(cursor, windows: session.windows),
              let window = session.windows[id] else { return }
        session.scroll(in: window, dx: delta.x * pixelsPerPoint, dy: delta.y * pixelsPerPoint, at: local)
    }

    private func dragMoved(_ drag: (hit: Hit, start: CGPoint, chrome: CGRect), session: any DisplaySession) {
        let dx = cursor.x - drag.start.x, dy = cursor.y - drag.start.y
        let area = workArea
        switch drag.hit {
        case .titleBar(let id):
            guard let window = session.windows[id] else { return }
            var start = drag
            // A snapped window pulled away takes back its own size, under the finger.
            if layout.snap(of: id) != nil, hypot(dx, dy) > 6 * ui {
                layout.setSnap(id, nil, current: drag.chrome, in: area, app: app(window))
                let size = layout.frame(for: id, app: app(window), in: area, minimum: minimumChrome(window))?.size ?? drag.chrome.size
                start.chrome = FreeDesktopLayout.unsnapped(size: size, from: drag.chrome, grab: drag.start, in: area)
                self.drag = start
            }
            guard layout.snap(of: id) == nil else { return }
            var frame = start.chrome.offsetBy(dx: dx, dy: dy)
            frame.origin.y = min(max(area.minY, frame.minY), area.maxY - titleBarHeight)
            let zone = FreeDesktopLayout.zone(at: cursor, in: area, edge: (directTouch ? 20 : 12) * ui)
                .flatMap { FreeDesktopLayout.allows($0, in: area, minimum: minimumChrome(window)) ? $0 : nil }
            if zone == nil {
                let others = stacking.filter { $0 != id && isVisible($0) }.compactMap { session.windows[$0] }
                    .filter { !$0.isAuxiliary && !$0.isFullscreen }.map { chromeRect($0) }
                frame = FreeDesktopLayout.magnetized(frame, others: others, in: area, threshold: 10 * ui)
            }
            if zone != pendingSnap {
                withAnimation(.snappy(duration: 0.2)) {
                    pendingSnap = zone
                    snapPreview = zone.map { FreeDesktopLayout.rect(for: $0, in: area, minimum: minimumChrome(window)) }
                }
                if zone != nil { UISelectionFeedbackGenerator().selectionChanged() }
            }
            dragged = frame
            session.configure(window, frame: linuxFrame(frame), state: ["maximized": false])
        case .resize(let id):
            guard let window = session.windows[id] else { return }
            if layout.snap(of: id) != nil { layout.setSnap(id, nil, current: drag.chrome, in: area, app: app(window)) }
            let minimum = minimumChrome(window)
            let frame = CGRect(x: drag.chrome.minX, y: drag.chrome.minY,
                               width: max(max(minimum.width, 120 * ui), drag.chrome.width + dx),
                               height: max(max(minimum.height, 80 * ui + titleBarHeight), drag.chrome.height + dy))
            dragged = frame
            session.configure(window, frame: linuxFrame(frame), state: ["maximized": false])
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

    /// The frontmost window that is not a menu or dialog: the one the keys act on.
    func frontWindow(in windows: [Int: RemoteWindow]) -> RemoteWindow? {
        stacking.reversed().filter { isVisible($0) }.compactMap { windows[$0] }.first { !$0.isAuxiliary }
    }

    /// ⌘⌥ and an arrow: the nearest window that way comes forward.
    func moveFocus(_ direction: YardLayout.Direction, session: (any DisplaySession)?) {
        guard let session, let front = frontWindow(in: session.windows) else { return }
        let frames = Dictionary(uniqueKeysWithValues: stacking.filter { $0 != front.id && isVisible($0) }
            .compactMap { session.windows[$0] }.filter { !$0.isAuxiliary }.map { ($0.id, chromeRect($0)) })
        guard let next = FreeDesktopLayout.neighbour(direction, from: chromeRect(front), among: frames) else { return }
        raise(next)
        focus(next, session)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func isZoomed(_ window: Int) -> Bool { layout.snap(of: window) == .maximized }

    /// The green button: fill the desktop above the dock, or go back to where it was.
    func toggleZoom(_ id: Int, _ session: any DisplaySession) {
        snap(id, isZoomed(id) ? nil : .maximized, session)
    }

    /// Snaps a window to a side, a corner or the whole work area, or (nil) back to its own
    /// frame, and focuses it.
    func snap(_ id: Int, _ snap: FreeDesktopLayout.Snap?, _ session: any DisplaySession) {
        guard let window = session.windows[id], !window.isAuxiliary else { return }
        if let snap, !FreeDesktopLayout.allows(snap, in: workArea, minimum: minimumChrome(window)) { return }
        raise(id)
        focus(id, session)
        layout.setSnap(id, snap, current: chromeRect(window), in: workArea, app: app(window))
        save()
        applyPlace(window, session)
    }

    private func applyPlace(_ window: RemoteWindow, _ session: any DisplaySession) {
        guard let frame = placedFrame(window), window.frame != frame else { return }
        session.configure(window, frame: frame, state: ["maximized": false])
    }

    /// Rotation, a new screen, toolbar changes and display scaling: every placed window is
    /// laid out again from the place the owner chose, so nothing drifts or leaves the desktop.
    func relayout(session: (any DisplaySession)?) {
        guard let session else { return }
        for window in session.windows.values where !window.isAuxiliary && !window.isFullscreen {
            applyPlace(window, session)
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
