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
        case desktopItem(String)
        case desktopMenu
        case titleBar(Int)
        case close(Int)
        case minimize(Int)
        case zoom(Int)
        case launchpadButton
        case panelButton
        case launcher(String)
        case launcherPage(Int)
        case content(Int, CGPoint)  // window id, point in window pixels
        case resize(Int)
        /// A window in the open Quick Switch strip, and its Stay Here.
        case switchItem(Int)
        case switchStay
        /// A row of the open pointer menu, and the rest of the menu.
        case menuItem(Int)
        case menuStay
    }

    typealias MenuItem = SceneMenuItem

    /// Quick Switch, whose strip this desktop hit-tests while it is open: the touch area and
    /// a TV's trackpad route every touch and click through here.
    weak var quickSwitch: QuickSwitcher?

    /// How much larger than a Mac at arm's length the desktop draws, for the distance it is
    /// seen from: title bars, the dock, the cursor and (through the DPI it asks Linux for)
    /// the apps' own text all grow by it, so a 4K TV across a room reads like a laptop.
    var ui: CGFloat = 1
    /// Every window's title bar: its controls' places for drawing and for hit-testing.
    var titleBar: WindowTitleBar { WindowTitleBar(ui: ui, touch: directTouch) }
    /// Laptop puts an auto-hiding floating dock at the bottom of the upper screen, without
    /// shrinking the guest's workArea. Its windows keep their title bars, and each shows in
    /// its snap, as a tile shows in its column.
    var detachedChrome = false {
        didSet {
            guard detachedChrome != oldValue else { return }
            laptopFilled.removeAll()
            fill.reset()
            laptopDockHovered = false
            laptopDockPinned = false
            panelPresented = false
        }
    }
    /// In Laptop mode (`detachedChrome`), the floating dock at the bottom of the upper screen
    /// stays hidden unless the pointer hovers near the bottom edge, a dock menu/popover is open,
    /// or the user reveals it from the controller HUD.
    private(set) var laptopDockHovered = false
    var laptopDockPinned = false

    var isDockVisible: Bool {
        guard detachedChrome else { return true }
        if launchpadOpen || menu.isOpen || panelPresented || laptopDockPinned || quickSwitch?.owner == .desktop {
            return true
        }
        return laptopDockHovered
    }

    func toggleLaptopDock() {
        if isDockVisible {
            laptopDockPinned = false
            launchpadOpen = false
            panelPresented = false
            closePointerMenu()
            laptopDockHovered = false
        } else {
            laptopDockPinned = true
        }
    }

    func updateLaptopDockHover() {
        guard detachedChrome, size.height > 0 else {
            laptopDockHovered = false
            return
        }
        if let drag {
            switch drag.hit {
            case .titleBar, .resize:
                laptopDockHovered = false
                return
            default:
                break
            }
        }
        let threshold: CGFloat = laptopDockHovered ? 88 * ui : 28 * ui
        let hovering = cursor.y >= size.height - threshold
        if hovering {
            laptopDockHovered = true
        } else if laptopDockHovered {
            laptopDockHovered = false
            laptopDockPinned = false
        }
    }
    /// The windows Laptop has filled its screen with since it opened: each once, so one the
    /// owner restores stays where the owner put it.
    private var laptopFilled: Set<Int> = []
    /// What each window was last configured to, and Laptop's hold on it (`LaptopFill`).
    @ObservationIgnored private var fill = LaptopFill()
    /// Laptop's upper screen below a title bar, in Linux pixels: what a filled window takes.
    private var laptopScreen: CGRect { linuxFrame(workArea) }
    var pointerArea: CGSize?
    var titleBarHeight: CGFloat { titleBar.height }
    var dockHeight: CGFloat { detachedChrome ? 0 : 76 * ui }
    var dockBottomInset: CGFloat { detachedChrome ? 0 : 10 * ui }
    private var dockGap: CGFloat { detachedChrome ? 0 : 8 * ui }
    var maximizedFrame: CGRect {
        let area = DesktopGeometry.maximizedFrame(size: size, titleBarHeight: titleBarHeight,
                                                 dockHeight: dockHeight, dockBottomInset: dockBottomInset, dockGap: dockGap)
        return CGRect(x: area.minX * pixelsPerPoint, y: area.minY * pixelsPerPoint,
                      width: area.width * pixelsPerPoint, height: area.height * pixelsPerPoint).integral
    }

    /// Where windows go: the desktop above the dock, in points. A window's whole frame,
    /// title bar included, stays inside it.
    var workArea: CGRect {
        CGRect(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height - dockHeight - dockBottomInset - dockGap))
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
    /// Native title-bar clearance, shared by drawing and pointer hit testing.
    var titleBarLeadingInsets: [Int: CGFloat] = [:]

    private(set) var snapPreview: CGRect?
    private(set) var snapPalette: FreeDesktopLayout.SnapPalette?
    private(set) var pendingSnap: FreeDesktopLayout.Snap?

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

    /// The window's smallest and largest content, in desktop points.
    private func contentLimits(_ window: RemoteWindow) -> (minimum: CGSize?, maximum: CGSize?) {
        func points(_ size: CGSize?) -> CGSize? {
            size.map { CGSize(width: $0.width / pixelsPerPoint, height: $0.height / pixelsPerPoint) }
        }
        return (points(window.minimumSize), points(window.maximumSize))
    }

    /// Whether the window can take the snap. Laptop shows a snapped window fitted into its
    /// snap, so there a resizable window held larger than the snap by its minimum size takes
    /// it too: laid out at the snap's shape grown to that minimum, and shown scaled down.
    func canSnap(_ snap: FreeDesktopLayout.Snap, _ window: RemoteWindow) -> Bool {
        let limits = contentLimits(window)
        return FreeDesktopLayout.accepts(snap, in: workArea, titleBar: titleBarHeight, minimum: limits.minimum,
                                         maximum: limits.maximum, scaled: detachedChrome)
    }

    /// Where the window belongs on this desktop by its place, in Linux pixels, if it has one.
    func placedFrame(_ window: RemoteWindow) -> CGRect? {
        layout.frame(for: window.id, app: app(window), in: workArea, minimum: minimumChrome(window)).map(linuxFrame)
    }

    /// Configures a window this session has not placed yet at its place. One that has no
    /// place gets its first one, and keeps it; one whose app is not known yet is placed
    /// without taking over a place kept under its id.
    func place(_ window: RemoteWindow, index: Int, session: any DisplaySession) {
        if placedFrame(window) == nil {
            let frame = placement(for: window, index: index)
            guard app(window) != nil || layout.places[window.id] == nil else {
                fill.release(window.id)
                session.configure(window, frame: frame, state: ["maximized": false])
                return
            }
            layout.setPreferred(window.id, frame: chromeRect(frame: frame), in: workArea, app: app(window))
            save()
        }
        applyPlace(window, session, always: true)
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
    /// Windows shown in iPadOS windows of their own, with their menus and dialogs: their
    /// scenes lay them out, so this desktop neither draws, hit-tests nor places them.
    var detached = Set<Int>()
    var dockFrames: [String: CGRect] = [:]
    /// The context menu of the dock, a desktop item or the Desktop menu, drawn in the space
    /// the cursor moves in and hit-tested here like the dock (`SceneMenu`).
    let menu = SceneMenu()
    /// The rows of each menu, from the views that own their actions.
    @ObservationIgnored var dockMenu: (@MainActor (String) -> [MenuItem])?
    @ObservationIgnored var desktopItemMenu: (@MainActor (String) -> [MenuItem])?
    @ObservationIgnored var desktopBackgroundMenu: (@MainActor () -> [MenuItem])?
    @ObservationIgnored var panelMenu: (@MainActor () -> [MenuItem])?
    /// Launchpad: every app, in a grid over the desktop.
    var desktopItemFrames: [String: CGRect] = [:]
    var desktopMenuFrame: CGRect = .zero
    var openDesktopItem: ((String) -> Void)?
    var launchpadOpen = false
    var panelPresented = false
    var launchpadButtonFrame: CGRect = .null
    var panelButtonFrame: CGRect = .null
    var launcherFrames: [String: CGRect] = [:]
    var launcherPage = 0
    var launcherPageFrames: [Int: CGRect] = [:]

    /// A press being dragged: what it started on, where the pointer and the window's whole
    /// frame (in points) were when it started, or when it last left a snap.
    private var drag: (hit: Hit, start: CGPoint, chrome: CGRect)?

    init(pixelsPerPoint: CGFloat) { self.pixelsPerPoint = pixelsPerPoint }

    /// The display server the windows come from: a new lifetime numbers its windows afresh,
    /// so every place, the stacking and the minimized windows of the last one are dropped
    /// before anything is placed. Call it before placing a ready session's windows.
    func enter(epoch: String?) {
        let before = layout
        layout.enter(epoch: epoch)
        guard layout.epoch != before.epoch else { return }
        stacking.removeAll()
        minimized.removeAll()
        liveWindows = nil
        save()
    }

    /// The computer has announced every window it has: places of windows it no longer has
    /// (closed while away, or from before a cold boot) are dropped.
    func windowsAnnounced(_ ids: Set<Int>) {
        let before = layout
        layout.prune(keeping: ids)
        if layout != before { save() }
    }

    /// The windows a ready session last showed, to tell a closed window from a reconnect.
    private let pointerClicks = PointerClickDriver()
    private var liveWindows: (session: ObjectIdentifier, ids: Set<Int>)?

    /// Follows the computer's windows. A window's place is forgotten when it closes: when it
    /// leaves a session that is still ready. A dropped or replaced connection forgets nothing,
    /// since window ids survive reconnects and parking.
    func sync(with windows: [RemoteWindow], session: (any DisplaySession)? = nil) {
        if session?.state != .ready || session.map(ObjectIdentifier.init) != liveWindows?.session {
            pointerClicks.cancel()
            cancelWindowDrag()
        }
        if let drag {
            switch drag.hit {
            case .titleBar(let id), .resize(let id):
                if !windows.contains(where: { $0.id == id }) { cancelWindowDrag() }
            default: break
            }
        }
        let ids = Set(windows.map(\.id))
        stacking.removeAll { !ids.contains($0) }
        for window in windows.sorted(by: { $0.id < $1.id }) where !stacking.contains(window.id) {
            stacking.append(window.id)
            if layout.isMinimized(window.id, app: app(window)) { minimized.insert(window.id) }
        }
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
        if minimized.remove(id) != nil { keepMinimized(id, false) }
    }

    /// The window ⌥Tab has selected: shown in front of the others, even from the dock,
    /// until the switch lands on it or is cancelled. Stacking itself does not change.
    var peek: Int?

    /// The windows to draw, back to front.
    var shownWindows: [Int] {
        var shown = stacking.filter { isVisible($0) && $0 != peek }
        if let peek, stacking.contains(peek) { shown.append(peek) }
        return shown
    }

    /// Application windows, most recently used first.
    func recentWindows(_ session: any DisplaySession) -> [Int] {
        session.windows.values.filter { !$0.isAuxiliary && !detached.contains($0.id) }.sorted { $0.raisedAt > $1.raisedAt }.map(\.id)
    }

    /// Quick Switch on the floating desktop: the selection is drawn in front (`peek`), with no
    /// geometry sent, and the switch lands by raising and focusing it.
    func switchTarget(session: (any DisplaySession)?) -> QuickSwitcher.Desktop {
        QuickSwitcher.Desktop(owner: .desktop, session: session,
                              preview: { [weak self] in self?.peek = $0 },
                              commit: { [weak self] window in
                                  self?.peek = nil
                                  self?.activate(window, session: session)
                              },
                              cancel: { [weak self] in self?.peek = nil })
    }

    /// A finger held on Launchpad opens Quick Switch to slide through. False when the finger
    /// is not on Launchpad.
    func beginSwitchHold(session: (any DisplaySession)?) -> Bool {
        guard let session, let quickSwitch, hitTest(cursor, windows: session.windows) == .launchpadButton else { return false }
        launchpadOpen = false
        quickSwitch.hold(recent: recentWindows(session), desktop: switchTarget(session: session))
        return quickSwitch.owner == .desktop
    }

    func trackSwitchHold(at point: CGPoint) { quickSwitch?.track(point) }
    func endSwitchHold() { quickSwitch?.release() }
    func cancelSwitchHold() { quickSwitch?.cancel(owner: .desktop) }

    /// Brings a window forward and gives it the keyboard.
    func activate(_ id: Int, session: (any DisplaySession)?) {
        guard let session else { return }
        raise(id)
        focus(id, session)
    }

    func minimize(_ id: Int) {
        minimized.insert(id)
        keepMinimized(id, true)
    }

    /// Minimized windows stay in the dock across launches, with their places.
    private func keepMinimized(_ id: Int, _ value: Bool) {
        let before = layout
        layout.setMinimized(id, value)
        if layout != before { save() }
    }

    func isVisible(_ id: Int) -> Bool { !minimized.contains(id) && !detached.contains(id) }

    /// The window's content rect in desktop points.
    func contentRect(_ window: RemoteWindow) -> CGRect {
        if window.isFullscreen { return CGRect(origin: .zero, size: size) }
        // Laptop shows a snapped window in its snap whatever size the app last committed: a
        // window still at its Tablet size, or one that cannot grow, is fitted inside it rather
        // than hanging off the top or stopping short of the hinge.
        if detachedChrome, !window.isAuxiliary, layout.place(for: window.id, app: app(window))?.snap != nil,
           let snapped = layout.frame(for: window.id, app: app(window), in: workArea, minimum: minimumChrome(window)) {
            return CGRect(x: snapped.minX, y: snapped.minY + titleBarHeight,
                          width: snapped.width, height: max(1, snapped.height - titleBarHeight))
        }
        // A window larger than Laptop's screen is shown scaled to fit it, title bar at the top.
        if detachedChrome, !window.isAuxiliary, LaptopFill.exceeds(window.frame.size, laptopScreen.size) {
            return CGRect(x: workArea.minX, y: workArea.minY + titleBarHeight,
                          width: workArea.width, height: max(1, workArea.height - titleBarHeight))
        }
        return CGRect(x: window.frame.minX / pixelsPerPoint, y: window.frame.minY / pixelsPerPoint + (window.isAuxiliary ? 0 : titleBarHeight),
               width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
    }

    /// One presentation map for rendering, trackpad/touch hit testing and auxiliary
    /// trees. Root geometry comes from committed surfaces, never pending requests.
    func surfaceFrames(in windows: [Int: RemoteWindow]) -> [Int: CGRect] {
        let covering = fullscreenWindow(in: windows)?.id
        var roots: [Int: CGRect] = [:]
        for window in windows.values where !window.isAuxiliary && isVisible(window.id) {
            guard covering == nil || covering == window.id else { continue }
            let viewport = contentRect(window)
            let natural = CGSize(width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
            let local = DesktopGeometry.surfaceFrame(
                natural: window.game == nil ? natural : viewport.size, available: viewport.size, resizing: false,
                fullscreen: window.isFullscreen)
            roots[window.id] = local.offsetBy(dx: viewport.minX, dy: viewport.minY)
        }
        let geometry = Dictionary(uniqueKeysWithValues: windows.values.filter { isVisible($0.id) }.map {
            ($0.id, DesktopGeometry.WindowGeometry(frame: $0.frame, parent: $0.transientFor))
        })
        let auxiliaries = DesktopGeometry.popupFrames(windows: geometry, rootFrames: roots,
            viewport: CGRect(origin: .zero, size: size), pixelsPerPoint: pixelsPerPoint, covering: covering)
        return roots.merging(auxiliaries) { root, _ in root }
    }

    func presentedChrome(_ window: RemoteWindow, surface: CGRect) -> CGRect {
        window.isAuxiliary || window.isFullscreen ? surface :
            surface.inset(by: UIEdgeInsets(top: -titleBarHeight, left: 0, bottom: 0, right: 0))
    }

    func inputMapping(for window: RemoteWindow, windows: [Int: RemoteWindow]) -> DesktopGeometry.SurfaceMapping? {
        guard let shown = surfaceFrames(in: windows)[window.id] else { return nil }
        return .init(shown: shown, remote: window.frame.size)
    }

    private func surfacePoint(_ point: CGPoint, window: RemoteWindow,
                              windows: [Int: RemoteWindow], captured: Bool = false) -> CGPoint? {
        inputMapping(for: window, windows: windows)?.point(point, captured: captured)
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
        if let row = menu.hit(point) { return row >= 0 ? .menuItem(row) : .menuStay }
        if quickSwitch?.owner == .desktop {
            if let item = quickSwitch?.item(at: point) { return .switchItem(item) }
            if quickSwitch?.staysAt(point) == true { return .switchStay }
        }
        let dockActive = detachedChrome ? isDockVisible : (fullscreenWindow(in: windows) == nil)
        if dockActive {
            if panelButtonFrame.contains(point) { return .panelButton }
            if launchpadButtonFrame.contains(point) { return .launchpadButton }
            for (id, frame) in dockFrames where frame.contains(point) { return .dock(id) }
        }
        if launchpadOpen {
            for (direction, frame) in launcherPageFrames where frame.contains(point) { return .launcherPage(direction) }
            for (id, frame) in launcherFrames where frame.contains(point) { return .launcher(id) }
            return .none
        }
        let surfaces = surfaceFrames(in: windows)
        for id in stacking.reversed() where isVisible(id) {
            guard let window = windows[id], let content = surfaces[id] else { continue }
            let chrome = presentedChrome(window, surface: content)
            guard chrome.contains(point) else { continue }
            if content.contains(point) {
                if !detachedChrome, !window.isAuxiliary, !window.isFullscreen,
                   point.x > content.maxX - 18 * ui, point.y > content.maxY - 18 * ui { return .resize(id) }
                guard let local = DesktopGeometry.remotePoint(point, shown: content, remote: window.frame.size) else { continue }
                // The application's own window controls are covered: there, it is title bar.
                if window.isOnDrawnControl(local) { return .titleBar(id) }
                return .content(id, local)
            }
            // The controls answer where DesktopWindow draws them, across the bar's height.
            switch titleBar.control(at: CGPoint(x: point.x - chrome.minX - (titleBarLeadingInsets[id] ?? 0), y: point.y - chrome.minY)) {
            case .close: return .close(id)
            case .minimize: return .minimize(id)
            case .zoom: return .zoom(id)
            case nil: return .titleBar(id)
            }
        }
        if fullscreenWindow(in: windows) != nil { return .none }
        if desktopMenuFrame.contains(point) { return .desktopMenu }
        for (id, frame) in desktopItemFrames where frame.contains(point) { return .desktopItem(id) }
        return .none
    }

    // MARK: Pointer

    func move(by delta: CGPoint, session: (any DisplaySession)?) {
        let bounds = pointerArea ?? size
        cursor = CGPoint(x: min(max(0, cursor.x + delta.x), bounds.width), y: min(max(0, cursor.y + delta.y), bounds.height))
        updateLaptopDockHover()
        guard let session else { return }
        if let drag {
            dragMoved(drag, session: session)
            return
        }
        hovered = hitTest(cursor, windows: session.windows)
        if case .menuItem(let row) = hovered { menu.hovered = row } else { menu.hovered = nil }
        if case .content(let id, let local) = hovered, let window = session.windows[id] {
            session.pointerMove(in: window, to: local)
        }
    }

    /// Opens the context menu at the cursor; false when there is nothing to show.
    private func openPointerMenu(_ items: [MenuItem]?) -> Bool {
        menu.show(items ?? [], at: cursor)
    }

    func closePointerMenu() {
        menu.close()
        if case .menuItem = hovered { hovered = .none }
    }

    /// A dock app's menu, above its icon: what holding it with a finger opens.
    func showDockMenu(_ id: String) {
        guard let frame = dockFrames[id], let items = dockMenu?(id) else { return }
        menu.show(items, at: CGPoint(x: frame.minX, y: frame.minY), above: true)
    }

    /// A desktop item's menu, over it.
    func showItemMenu(_ id: String) {
        guard let frame = desktopItemFrames[id], let items = desktopItemMenu?(id) else { return }
        menu.show(items, at: CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The Desktop menu, below its button.
    func showDesktopMenu() {
        guard let items = desktopBackgroundMenu?() else { return }
        menu.show(items, at: CGPoint(x: desktopMenuFrame.minX, y: desktopMenuFrame.maxY + 4))
    }

    /// Laptop's far-right dock menu, drawn in the scene above the dock so the pointer
    /// stays on top of it and can hover and click every row.
    func showPanelMenu() {
        guard let items = panelMenu?() else { return }
        let anchor = panelButtonFrame.isNull
            ? cursor
            : CGPoint(x: panelButtonFrame.maxX, y: panelButtonFrame.minY - 6 * ui)
        menu.show(items, at: anchor, above: true)
    }

    func click(button: Int = 1, session: (any DisplaySession)?, open: (String) -> Void) {
        guard let session else { return }
        let hit = hitTest(cursor, windows: session.windows)
        // An open menu takes the click: a row chooses, anywhere else closes it, as on a Mac.
        if menu.isOpen {
            switch hit {
            case .menuItem(let index):
                laptopDockPinned = false
                menu.choose(index)
            case .menuStay: break
            default: closePointerMenu()
            }
            return
        }
        switch hit {
        case .switchItem(let id):
            laptopDockPinned = false
            quickSwitch?.choose(id)
            return
        case .switchStay:
            quickSwitch?.cancel()
            return
        case .launchpadButton where button == 3:
            // A secondary click on Launchpad: the windows to choose from.
            launchpadOpen = false
            quickSwitch?.present(recent: recentWindows(session), desktop: switchTarget(session: session))
            return
        default:
            // A click anywhere else while the strip is open closes it, and nothing else.
            if quickSwitch?.owner == .desktop {
                quickSwitch?.cancel()
                return
            }
        }
        if case .launcherPage(let direction) = hit {
            launcherFrames = [:]
            launcherPageFrames = [:]
            launcherPage = max(0, launcherPage + direction)
            return
        }
        if launchpadOpen, hit != .launchpadButton, hit != .panelButton {
            // Opening an app closes Launchpad once the app is in front (`AppModel.openOnDesktop`).
            if case .launcher(let id) = hit {
                laptopDockPinned = false
                open(id)
            } else {
                launchpadOpen = false
            }
            return
        }
        switch hit {
        case .desktopMenu: _ = openPointerMenu(desktopBackgroundMenu?())
        case .desktopItem(let id):
            if button == 3 { _ = openPointerMenu(desktopItemMenu?(id)) } else { openDesktopItem?(id) }
        case .launchpadButton: launchpadOpen.toggle()
        case .panelButton:
            launchpadOpen = false
            if detachedChrome {
                showPanelMenu()
            } else {
                panelPresented.toggle()
            }
        case .launcher(let id):
            laptopDockPinned = false
            open(id)
        case .launcherPage: break
        case .dock(let id):
            if button == 3 {
                _ = openPointerMenu(dockMenu?(id))
            } else {
                laptopDockPinned = false
                open(id)
            }
        case .close(let id): if let window = session.windows[id] { session.closeDiagnosed(window, context: .init(cursor: cursor)) }
        case .minimize(let id): minimize(id)
        case .zoom(let id): toggleZoom(id, session)
        case .titleBar(let id), .resize(let id): raise(id); focus(id, session)
        case .switchItem, .switchStay, .menuItem, .menuStay:
            break
        case .content(let id, let local):
            laptopDockPinned = false
            guard let window = session.windows[id] else { return }
            if !window.isAuxiliary { raise(id) }
            focus(id, session)
            session.pointerMove(in: window, to: local)
            pointerClicks.click(in: window, session: session, at: local, button: button)
        case .none:
            laptopDockPinned = false
        }
    }

    func beginDrag(session: (any DisplaySession)?) {
        pointerClicks.cancel()
        closePointerMenu()
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

    /// Abandon native window placement when its desktop or connection goes away.
    func cancelWindowDrag() {
        guard let drag else { return }
        switch drag.hit {
        case .titleBar, .resize:
            self.drag = nil; dragged = nil; snapPalette = nil; snapPreview = nil; pendingSnap = nil
        default: break
        }
    }

    func endDrag(session: (any DisplaySession)?) {
        defer { drag = nil; snapPalette = nil; snapPreview = nil; pendingSnap = nil; dragged = nil }
        guard let drag, let session else { return }
        switch drag.hit {
        case .content(let id, let pressedPoint):
            guard let window = session.windows[id] else { return }
            // Release still belongs to the captured window even if it was obscured.
            let local = surfacePoint(cursor, window: window, windows: session.windows, captured: true)
                ?? pressedPoint
            session.pointerButton(in: window, button: 1, pressed: false, at: local)
        case .titleBar(let id), .resize(let id):
            guard let window = session.windows[id], let frame = dragged else { return }
            // Where it was let go is where it returns to from a snap.
            layout.setPreferred(id, frame: frame, in: workArea, app: app(window))
            if let snap = pendingSnap, canSnap(snap, window) {
                layout.setSnap(id, snap, current: frame, in: workArea, app: app(window))
                applyPlace(window, session, always: true)
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
              let window = session.windows[id],
              let mapped = inputMapping(for: window, windows: session.windows)?.delta(delta) else { return }
        session.scroll(in: window, dx: mapped.x, dy: mapped.y, at: local)
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
            if hypot(dx, dy) > 12 * ui {
                snapPalette = FreeDesktopLayout.SnapPalette(in: area, scale: ui) { snap, _ in self.canSnap(snap, window) }
            }
            let zone: FreeDesktopLayout.Snap?
            if let palette = snapPalette, palette.frame.contains(cursor) {
                zone = palette.selection(at: cursor)
            } else {
                zone = FreeDesktopLayout.zone(at: cursor, in: area, edge: (directTouch ? 20 : 12) * ui)
                    .flatMap { canSnap($0, window) ? $0 : nil }
            }
            if zone == nil {
                let others = stacking.filter { $0 != id && isVisible($0) }.compactMap { session.windows[$0] }
                    .filter { !$0.isAuxiliary && !$0.isFullscreen }.map { chromeRect($0) }
                frame = FreeDesktopLayout.magnetized(frame, others: others, in: area, threshold: 10 * ui)
            }
            if zone != pendingSnap {
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.2)) {
                    pendingSnap = zone
                    snapPreview = zone.map { FreeDesktopLayout.rect(for: $0, in: area, minimum: minimumChrome(window)) }
                }
                if zone != nil { UISelectionFeedbackGenerator().selectionChanged() }
            }
            dragged = frame
            fill.release(id)
            session.configure(window, frame: linuxFrame(frame), state: ["maximized": false])
        case .resize(let id):
            guard let window = session.windows[id] else { return }
            if layout.snap(of: id) != nil { layout.setSnap(id, nil, current: drag.chrome, in: area, app: app(window)) }
            let minimum = minimumChrome(window)
            let frame = CGRect(x: drag.chrome.minX, y: drag.chrome.minY,
                               width: max(max(minimum.width, 120 * ui), drag.chrome.width + dx),
                               height: max(max(minimum.height, 80 * ui + titleBarHeight), drag.chrome.height + dy))
            dragged = frame
            fill.release(id)
            session.configure(window, frame: linuxFrame(frame), state: ["maximized": false])
        case .content(let id, _):
            guard let window = session.windows[id] else { return }
            if let local = surfacePoint(cursor, window: window, windows: session.windows, captured: true) {
                session.pointerMove(in: window, to: local)
            }
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

    /// Fullscreen sizing belongs to the compositor. On exit the view supplies the
    /// last ordinary committed geometry, if it observed one before fullscreen.
    func applyFullscreen(_ window: RemoteWindow, entered: Bool, restore: CGRect?, session: (any DisplaySession)?) {
        guard let session, !detached.contains(window.id) else { return }
        if window.isFullscreen {
            if entered { raise(window.id) }
        } else if fill.isHeld(window.id) {
            // Laptop's layout, not the size before full screen, is where it goes back to.
            applyPlace(window, session, always: true)
        } else if let previous = restore {
            fill.release(window.id)
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
    @discardableResult
    func snap(_ id: Int, _ snap: FreeDesktopLayout.Snap?, _ session: any DisplaySession) -> Bool {
        guard let window = session.windows[id], !window.isAuxiliary, !detached.contains(id), app(window) != nil,
              size.width > 0, size.height > 0 else { return false }
        if let snap, !canSnap(snap, window) { return false }
        raise(id)
        focus(id, session)
        layout.setSnap(id, snap, current: chromeRect(window), in: workArea, app: app(window))
        save()
        applyPlace(window, session, always: true)
        return placedFrame(window) != nil
    }

    /// Laptop's upper screen shows one app at a time, like a laptop's maximized windows: every
    /// app window that can fill the desktop does, once, without changing which one is in front.
    /// A window held larger than the screen by its minimum size fills it at the screen's shape,
    /// scaled down (`canSnap`). Their Tablet places are another arrangement and stay as they were.
    func fillWorkArea(_ session: any DisplaySession) {
        guard size.width > 0, size.height > 0 else { return }
        let candidates = session.windows.values.filter { !detached.contains($0.id) }.map { window in
            let limits = contentLimits(window)
            return FreeDesktopLayout.FillCandidate(id: window.id, app: app(window), minimum: limits.minimum ?? .zero,
                                                   maximum: limits.maximum, isAuxiliary: window.isAuxiliary,
                                                   isFullscreen: window.isFullscreen)
        }
        let filling = layout.windowsToFill(candidates, in: workArea, titleBar: titleBarHeight, filled: laptopFilled)
        for id in filling {
            guard let window = session.windows[id] else { continue }
            laptopFilled.insert(id)
            layout.setSnap(id, .maximized, current: chromeRect(window), in: workArea, app: app(window))
            applyPlace(window, session, always: true)
        }
        if !filling.isEmpty { save() }
    }

    /// Where the window is configured by its place: on Laptop, `LaptopFill`'s layout, which
    /// maximizes a window filling the screen; elsewhere its place, a snap fitted to the
    /// window's limits.
    private func laidOut(_ window: RemoteWindow) -> LaptopFill.Layout? {
        guard !window.isFullscreen, let frame = placedFrame(window) else { return nil }
        let snap = layout.snap(of: window.id)
        if detachedChrome {
            return LaptopFill.layout(frame, snap: snap, screen: laptopScreen,
                                     minimum: window.minimumSize, maximum: window.maximumSize)
        }
        guard snap != nil else { return LaptopFill.Layout(frame: frame, maximized: false, held: false) }
        guard let fitted = WindowSizePolicy.fitting(frame, minimum: window.minimumSize,
            maximum: window.maximumSize, fullscreen: false) else { return nil }
        return LaptopFill.Layout(frame: WindowSizePolicy.centred(fitted, in: frame), maximized: false, held: false)
    }

    /// Configures the window to its place, when it is not there already (or `always`).
    private func applyPlace(_ window: RemoteWindow, _ session: any DisplaySession, always: Bool = false) {
        guard let laid = laidOut(window) else { return }
        let needed = always || fill.needsConfigure(window.id, laid, current: window.frame)
        fill.laidOut(window.id, laid, current: window.frame, configured: needed)
        guard needed else { return }
        session.configure(window, frame: laid.frame, state: ["maximized": laid.maximized])
    }

    /// Laptop puts back a window the app resized off its layout (`LaptopFill`): Steam
    /// reloading, or a browser restoring the size it saved.
    func holdLayout(_ session: any DisplaySession) {
        guard case .ready = session.state else { return }
        fill.keep(Set(session.windows.keys))
        guard detachedChrome else { return }
        for window in session.windows.values where !window.isAuxiliary && !window.isFullscreen && !detached.contains(window.id) {
            guard let laid = fill.restore(window.id, committed: window.frame) else { continue }
            session.configure(window, frame: laid.frame, state: ["maximized": laid.maximized])
        }
    }

    /// Rotation, a new screen, toolbar changes and display scaling: every placed window is
    /// laid out again from the place the owner chose, so nothing drifts or leaves the desktop.
    func relayout(session: (any DisplaySession)?) {
        guard let session else { return }
        for window in session.windows.values where !window.isAuxiliary && !window.isFullscreen && !detached.contains(window.id) {
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
