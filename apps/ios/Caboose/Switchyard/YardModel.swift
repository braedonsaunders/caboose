import CabooseKit
import Observation
import SwiftUI

/// Switchyard on the device's own screen: the computer's windows tiled in columns on a track
/// that scrolls sideways, each laid out by Linux at exactly its tile's size.
///
/// The layout itself is `YardLayout` (CabooseKit). This model holds where the screen is on
/// the track, the drags in progress, and the conversation with the display: every tile's
/// rect, at the screen position it is shown at, becomes that window's Linux geometry, so a
/// popup an app opens lands over its tile and nothing overlaps on screen.
@MainActor @Observable
final class YardModel {
    private(set) var memory = YardMemory()
    var layout: YardLayout { memory.layout }
    private(set) var metrics = YardMetrics(size: CGSize(width: 390, height: 700))
    /// How far along the track the screen is, in points.
    private(set) var scroll: CGFloat = 0
    var pixelsPerPoint: CGFloat = 2

    /// A tile being carried by its title bar.
    struct Carry: Equatable {
        let window: Int
        /// The tile's rect on screen when it was picked up.
        let origin: CGRect
        /// The tile's rect on screen as it is carried.
        var rect: CGRect
        var drop: YardLayout.Drop?
        var proposal: YardLayout?
        var proposedScroll: CGFloat?
        var snap: FreeDesktopLayout.Snap?
        var regionFrame: CGRect?
        /// Where it would land, on screen.
        var preview: CGRect?
    }
    private(set) var carry: Carry?
    private var carryScroll: CGFloat?
    private var carryCancelled = false
    var snapPalette: FreeDesktopLayout.SnapPalette? {
        guard let carry else { return nil }
        return FreeDesktopLayout.SnapPalette(in: CGRect(origin: .zero, size: metrics.size), allows: { snap, slots in
            self.layout.snapping(carry.window, to: snap, layout: slots, in: self.metrics) != nil
        })
    }
    func cancelCarry() {
        guard carry != nil else { return }
        carryCancelled = true
        if let carryScroll { scroll = carryScroll }
        carry = nil
        carryScroll = nil
        coverProgress = 0
    }
    /// Called after the recognizer ends or resets; a lifecycle cancellation fences
    /// remaining changed/ended callbacks until this gesture is finished.
    func finishCarryGesture() {
        cancelCarry()
        carryCancelled = false
    }
    /// The gap being dragged, while it is.
    private(set) var activeHandle: YardLayout.Handle.Kind?
    var overviewOpen = false
    var launcherOpen = false

    weak var session: (any DisplaySession)?
    /// Saves the yard for the computer it belongs to.
    var storageKey: String? {
        didSet {
            guard storageKey != oldValue else { return }
            memory = YardMemory.decoded(from: storageKey.flatMap { UserDefaults.standard.data(forKey: $0) })
            scroll = 0
            zoomed = nil
            coverProgress = 0
            invalidate()
        }
    }

    /// The geometry each window was last sent, in Linux pixels, so nothing is sent twice.
    private var sent: [Int: CGRect] = [:]
    /// The same bounded resize reconciliation used by cards. A client's later
    /// size change must not be hidden by the last-request deduplication cache.
    private var fitting: [Int: CardWindowFit] = [:]
    /// Windows asked for a new size whose picture may not have caught up yet: their last
    /// picture is stretched over the tile meanwhile.
    private var settling: [Int: UUID] = [:]
    /// Dialogs already fitted over their window.
    private var placedDialogs = Set<Int>()
    private var lastLiveApply = Date.distantPast
    /// The tiled window that asked to cover the whole screen (a video, a slideshow, a game).
    var fullscreenWindow: Int? {
        layout.windows.first { session?.windows[$0]?.isFullscreen == true }
    }
    /// The window zoomed to the whole screen, edge to edge, until it is pulled back.
    private(set) var zoomed: Int?
    /// The window covering the workspace above the dock until pulled back into its tile:
    /// zoomed, or full screen at the app's own request. Desktop navigation stays visible.
    var coverWindow: Int? { zoomed.flatMap { layout.contains($0) ? $0 : nil } ?? fullscreenWindow }
    /// How far the covering window is back toward its tile: 0 covering, 1 in its tile.
    private(set) var coverProgress: CGFloat = 0
    /// The workspace above the dock that a covering window fills, in points.
    var screenSize: CGSize = .zero {
        didSet { if screenSize != oldValue { cancelCarry(); if coverWindow != nil { apply() } } }
    }

    // MARK: Screen

    func resize(to size: CGSize) {
        guard size.width > 0, size.height > 0, size != metrics.size else { return }
        cancelCarry()
        metrics = YardMetrics(size: size)
        scroll = layout.focused.map { layout.scroll(revealing: $0, from: scroll, in: metrics) } ?? min(scroll, layout.maximumScroll(in: metrics))
        apply()
    }

    /// Each window's tile on screen, scroll applied.
    var tiles: [Int: CGRect] {
        layout.frames(in: metrics).mapValues { $0.offsetBy(dx: -scroll, dy: 0) }
    }

    /// Where each window itself is on screen: its tile below the tile's title bar. This is
    /// the window's Linux geometry, and where its input, dialogs and popups are placed.
    var contents: [Int: CGRect] {
        tiles.mapValues { metrics.content(ofTile: $0) }
    }

    /// The columns on screen, and one either side so a scroll or a move animates into view.
    var liveWindows: Set<Int> {
        let visible = Set(layout.visibleColumns(at: scroll, in: metrics))
        var live = Set<Int>()
        for (index, column) in layout.columns.enumerated() where visible.contains(column.id) {
            for neighbour in max(0, index - 1)...min(layout.columns.count - 1, index + 1) {
                live.formUnion(layout.columns[neighbour].windows)
            }
        }
        if let carry { live.insert(carry.window) }
        return live
    }

    /// Whether a window's picture is stretched to its tile: while its gap is dragged, and
    /// briefly after each new size.
    func stretches(_ window: Int) -> Bool { settling[window] != nil || activeHandle != nil }

    // MARK: Windows

    /// Brings the yard in line with the computer's windows: closed ones leave the track, new
    /// application windows take a column beside the focused one (at the width their app was
    /// last given), and dialogs are fitted over the window they belong to.
    func sync(_ windows: [Int: RemoteWindow], appClass: (RemoteWindow) -> String?) {
        if let carry, windows[carry.window] == nil { cancelCarry() }
        let tiled = windows.values.filter { !$0.isAuxiliary }
        let before = layout
        // Tiles make way for a new window, and close over a gone one, in one movement.
        withAnimation(.smooth(duration: 0.42, extraBounce: 0.06)) {
            memory.layout.prune(keeping: Set(tiled.map(\.id)), in: metrics)
            for window in tiled.sorted(by: { $0.raisedAt < $1.raisedAt }) where !layout.contains(window.id) {
                memory.layout.insert(window.id, width: memory.width(for: appClass(window)), in: metrics)
            }
        }
        sent = sent.filter { windows[$0.key] != nil }
        fitting = fitting.filter { windows[$0.key] != nil }
        settling = settling.filter { windows[$0.key] != nil }
        if let zoomed, windows[zoomed] == nil {
            self.zoomed = nil
            coverProgress = 0
        }
        placedDialogs.formIntersection(windows.keys)
        if layout != before {
            cancelCarry()
            if let focused = layout.focused, layout.focused != before.focused { reveal(focused) }
            scroll = min(scroll, layout.maximumScroll(in: metrics))
            save()
        }
        for window in windows.values where window.isAuxiliary && !window.isOverrideRedirect && !placedDialogs.contains(window.id) {
            placedDialogs.insert(window.id)
            fitDialog(window, parent: window.transientFor.flatMap { windows[$0] })
        }
        apply()
    }

    /// Sends every tile's geometry that changed. During a gap drag it is sent at most a few
    /// times a second, and stretched pictures cover the gaps between.
    func apply(live: Bool = false) {
        guard carry == nil, let session else { return }
        if live {
            guard Date().timeIntervalSince(lastLiveApply) > 0.12 else { return }
            lastLiveApply = Date()
        }
        let scale = pixelsPerPoint
        let cover = coverWindow
        for (id, content) in contents {
            guard let window = session.windows[id] else { continue }
            let rect = id == cover && screenSize != .zero ? CGRect(origin: .zero, size: screenSize) : content
            send(window, CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral, session)
        }
    }

    private func send(_ window: RemoteWindow, _ proposed: CGRect, _ session: any DisplaySession) {
        guard let target = WindowSizePolicy.fitting(proposed, minimum: window.minimumSize,
            maximum: window.maximumSize, fullscreen: window.isFullscreen) else { return }
        let changed = sent[window.id] != target
        let correction = fitting[window.id, default: CardWindowFit()].shouldCorrect(
            frame: window.frame, target: target, now: ProcessInfo.processInfo.systemUptime)
        guard changed || correction else { return }
        sent[window.id] = target
        guard window.frame != target else { return }
        if window.frame.size != target.size { settle(window.id) }
        session.configure(window, frame: target, state: ["maximized": false])
    }

    /// Stretches the window's last picture over its new tile until Linux redraws it at that
    /// size, or for a moment at most: an app that keeps its own size is then shown as it is.
    private func settle(_ window: Int) {
        let token = UUID()
        settling[window] = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            if self?.settling[window] == token { self?.settling.removeValue(forKey: window) }
        }
    }

    /// The display server the windows come from: a new lifetime numbers its windows afresh,
    /// so the track of the last one is cleared (hand-chosen widths stay). Call it before
    /// syncing a ready session's windows.
    func enter(epoch: String?) {
        let before = memory
        memory.enter(epoch: epoch)
        guard memory.epoch != before.epoch else { return }
        scroll = 0
        zoomed = nil
        coverProgress = 0
        invalidate()
        save()
    }

    /// The display was reconnected or reconfigured: everything is sent afresh.
    func invalidate() {
        cancelCarry()
        sent.removeAll()
        fitting.removeAll()
        placedDialogs.removeAll()
    }

    /// A dialog sits centred over its window's tile, made smaller if the screen is.
    private func fitDialog(_ dialog: RemoteWindow, parent: RemoteWindow?) {
        guard let session else { return }
        let scale = pixelsPerPoint
        let available = coverWindow == nil || screenSize == .zero ? metrics.size : screenSize
        let bounds = CGRect(origin: .zero, size: available)
        let around = parent.flatMap { $0.id == coverWindow ? bounds : contents[$0.id] } ?? bounds
        let margin: CGFloat = 12
        let width = min(dialog.frame.width / scale, max(1, available.width - 2 * margin))
        let height = min(dialog.frame.height / scale, max(1, available.height - 2 * margin))
        var origin = CGPoint(x: around.midX - width / 2, y: around.midY - height / 2)
        origin.x = min(max(margin, origin.x), available.width - margin - width)
        origin.y = min(max(margin, origin.y), available.height - margin - height)
        let target = CGRect(x: origin.x * scale, y: origin.y * scale, width: width * scale, height: height * scale).integral
        if dialog.frame != target { session.configure(dialog, frame: target) }
        session.focus(dialog)
    }

    /// The window the keyboard goes to: the focused tile, or a dialog over it.
    func keyTarget(in windows: [Int: RemoteWindow]) -> Int? {
        guard let focused = layout.focused else { return nil }
        let dialogs = windows.values.filter { $0.isAuxiliary && !$0.isOverrideRedirect && ($0.transientFor == focused || $0.transientFor == nil) }
        return dialogs.max { $0.id < $1.id }?.id ?? focused
    }

    // MARK: Focus

    /// Focuses a window: the keyboard goes to it, Linux raises it, and the screen moves along
    /// the track just enough to show its column.
    func focus(_ window: Int, animated: Bool = true) {
        guard layout.contains(window) else { return }
        let changed = layout.focused != window
        memory.layout.focus(window)
        if let session, let remote = session.windows[window] { session.focus(remote) }
        reveal(window, animated: animated)
        if changed { save() }
    }

    /// Moves along the track to show a window's column, if it is not already in view.
    func reveal(_ window: Int, animated: Bool = true) {
        let target = layout.scroll(revealing: window, from: scroll, in: metrics)
        guard target != scroll else { return }
        if animated {
            withAnimation(.smooth(duration: 0.42, extraBounce: 0.06)) { scroll = target }
        } else {
            scroll = target
        }
        apply()
    }

    // MARK: Quick Switch

    /// Where the track was before Quick Switch started showing windows.
    private var scrollBeforePeek: CGFloat?

    /// Slides the track to show a window's column for Quick Switch, telling Linux nothing:
    /// no window is configured until the switch lands.
    func peek(_ window: Int) {
        guard layout.contains(window) else { return }
        if scrollBeforePeek == nil { scrollBeforePeek = scroll }
        let target = layout.scroll(revealing: window, from: scroll, in: metrics)
        guard target != scroll else { return }
        withAnimation(.smooth(duration: 0.3)) { scroll = target }
    }

    /// Ends showing windows: staying where the track is now, or sliding back.
    func endPeek(keep: Bool) {
        guard let before = scrollBeforePeek else { return }
        scrollBeforePeek = nil
        if !keep, before != scroll { withAnimation(.smooth(duration: 0.3)) { scroll = before } }
        apply()
    }

    /// Quick Switch on the yard: windows are shown by sliding the track, and the switch lands
    /// by focusing the window, which sends the geometry of where the track ended.
    func switchTarget() -> QuickSwitcher.Desktop {
        QuickSwitcher.Desktop(owner: .yard, session: session,
                              preview: { [weak self] in self?.peek($0) },
                              commit: { [weak self] window in
                                  self?.focus(window)
                                  self?.endPeek(keep: true)
                              },
                              cancel: { [weak self] in self?.endPeek(keep: false) })
    }

    func moveFocus(_ direction: YardLayout.Direction) {
        guard let next = layout.window(direction) else { bump(); return }
        focus(next)
    }

    func moveFocused(_ direction: YardLayout.Direction) {
        guard let focused = layout.focused else { return }
        var changed = false
        withAnimation(.smooth(duration: 0.4, extraBounce: 0.08)) { changed = memory.layout.moveFocused(direction, in: metrics) }
        guard changed else { bump(); return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        reveal(focused)
        committed()
    }

    private func bump() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5) }

    // MARK: Widths

    func cycleWidth() {
        guard let column = layout.focusedColumnIndex.map({ layout.columns[$0].id }) else { return }
        withAnimation(.smooth(duration: 0.4, extraBounce: 0.08)) { memory.layout.cycleWidth(column: column, in: metrics) }
        afterWidthChange()
    }

    func toggleFullWidth(_ window: Int? = nil) {
        guard let index = (window ?? layout.focused).flatMap(layout.columnIndex(of:)) else { return }
        withAnimation(.smooth(duration: 0.4, extraBounce: 0.08)) { memory.layout.toggleFullWidth(column: layout.columns[index].id, in: metrics) }
        afterWidthChange()
    }

    func setWidth(_ fraction: CGFloat, of window: Int) {
        guard let index = layout.columnIndex(of: window) else { return }
        withAnimation(.smooth(duration: 0.4, extraBounce: 0.08)) { memory.layout.setWidth(fraction, column: layout.columns[index].id, in: metrics) }
        afterWidthChange()
    }

    private func afterWidthChange() {
        UISelectionFeedbackGenerator().selectionChanged()
        if let focused = layout.focused { reveal(focused) }
        committed()
    }

    // MARK: Gap drags

    private var handleStart: (width: CGFloat, split: CGFloat)?
    private var lastDetent: CGFloat?

    func dragHandle(_ handle: YardLayout.Handle.Kind, translation: CGSize) {
        if activeHandle != handle {
            activeHandle = handle
            lastDetent = nil
            switch handle {
            case .width(let column):
                handleStart = (layout.column(id: column).map { layout.width(of: $0, in: metrics) } ?? 0, 0)
            case .split:
                handleStart = (0, 0)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        guard let start = handleStart else { return }
        switch handle {
        case .width(let column):
            memory.layout.drag(column: column, toWidth: max(YardMetrics.minimumTile.width, start.width + translation.width), in: metrics)
            // A tick as the width passes each preset.
            if let width = layout.column(id: column)?.width,
               let detent = metrics.presets.first(where: { abs($0 - width) < 0.012 }), detent != lastDetent {
                lastDetent = detent
                UISelectionFeedbackGenerator().selectionChanged()
            }
        case .split(let column, let position):
            memory.layout.dragSplit(column: column, below: position, by: translation.height - start.split, in: metrics)
            handleStart = (start.width, translation.height)
        }
        apply(live: true)
    }

    func endHandle(velocity: CGSize) {
        guard let handle = activeHandle else { return }
        withAnimation(.smooth(duration: 0.38, extraBounce: 0.1)) {
            switch handle {
            case .width(let column): memory.layout.snapWidth(column: column, velocity: velocity.width, in: metrics)
            case .split(let column, let position): memory.layout.snapSplit(column: column, below: position, in: metrics)
            }
            activeHandle = nil
        }
        handleStart = nil
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        if let focused = layout.focused { reveal(focused) }
        committed()
    }

    /// The width a column would show while its gap is dragged, as a fraction label.
    func widthLabel(column: Int) -> String? {
        guard let width = layout.column(id: column)?.width else { return nil }
        let names: [(CGFloat, String)] = [(1.0 / 3, "⅓"), (0.5, "½"), (2.0 / 3, "⅔"), (1, "Full")]
        return names.min { abs($0.0 - width) < abs($1.0 - width) }.map { abs($0.0 - width) < 0.04 ? $0.1 : "\(Int((width * 100).rounded()))%" }
    }

    // MARK: Carrying a tile

    func carry(_ window: Int, by translation: CGSize, at point: CGPoint) {
        guard !carryCancelled else { return }
        guard layout.contains(window) else { cancelCarry(); return }
        if carry?.window != window {
            carryScroll = scroll
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        guard let start = carry?.origin ?? (coverWindow == window ? CGRect(origin: .zero, size: metrics.size) : tiles[window]) else { return }
        let shrink = min(1, 240 / max(1, start.width))
        let grab = CGPoint(x: point.x - translation.width, y: point.y - translation.height)
        let rect = CGRect(x: point.x - (grab.x - start.minX) * shrink,
                          y: point.y - (grab.y - start.minY) * shrink,
                          width: start.width * shrink, height: start.height * shrink)
        if carry == nil { carry = Carry(window: window, origin: start, rect: rect) }
        let palette = snapPalette
        let region = palette?.regions.first { $0.enabled && $0.frame.contains(point) }
        let proposal = region.flatMap { layout.snapping(window, to: $0.snap, layout: $0.layout,
                                                        in: metrics) }
        // Palette gaps and disabled choices never fall through to the underlying tiles.
        let overPalette = palette?.frame.contains(point) == true
        if !overPalette {
            if point.x < 36 { nudge(by: -14) }
            else if point.x > metrics.size.width - 36 { nudge(by: 14) }
        }
        let drop = overPalette || !CGRect(origin: .zero, size: metrics.size).contains(point) ? nil : layout.drop(for: window, at: CGPoint(x: point.x + scroll, y: point.y), in: metrics)
        var after = proposal
        if after == nil, let drop {
            var candidate = layout
            if candidate.move(window, to: drop, in: metrics) { after = candidate }
        }
        let landingScroll = after.map { candidate -> CGFloat in
            if let region, let frame = candidate.frames(in: metrics)[window] {
                let slot = FreeDesktopLayout.rect(for: region.snap, in: CGRect(x: 0, y: 0, width: 6, height: 6))
                let leading = frame.minX - metrics.outerGap - slot.minX / 6 * (metrics.size.width - 2 * metrics.outerGap + metrics.gap)
                return min(candidate.maximumScroll(in: metrics), max(0, leading))
            }
            return candidate.scroll(revealing: window, from: scroll, in: metrics)
        }
        let preview = after?.frames(in: metrics)[window].map { $0.offsetBy(dx: -(landingScroll ?? scroll), dy: 0) }
        if preview != carry?.preview, preview != nil { UISelectionFeedbackGenerator().selectionChanged() }
        carry = Carry(window: window, origin: start, rect: rect, drop: drop, proposal: after,
                      proposedScroll: landingScroll, snap: region?.snap, regionFrame: region?.frame, preview: preview)
    }

    private func nudge(by delta: CGFloat) {
        let target = min(layout.maximumScroll(in: metrics), max(0, scroll + delta))
        guard target != scroll else { return }
        scroll = target
    }

    func drop() {
        guard let carry, let proposal = carry.proposal else { cancelCarry(); return }
        let wasCover = coverWindow == carry.window
        withAnimation(.smooth(duration: 0.42, extraBounce: 0.1)) {
            memory.layout = proposal
            scroll = carry.proposedScroll ?? scroll
            self.carry = nil
            carryScroll = nil
            if wasCover { zoomed = nil; coverProgress = 0 }
        }
        if wasCover, let remote = session?.windows[carry.window], remote.isFullscreen {
            exitAppFullscreen(carry.window)
        }
        if let remote = session?.windows[carry.window] { session?.focus(remote) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        committed()
    }

    // MARK: Scrolling

    private var scrollStart: CGFloat?

    /// Sliding along the dock's cars or swiping in from an edge: the screen follows, with resistance past
    /// the ends.
    func scrub(by delta: CGFloat) {
        if scrollStart == nil { scrollStart = scroll }
        guard let start = scrollStart else { return }
        let maximum = layout.maximumScroll(in: metrics)
        var target = start + delta
        if target < 0 { target = -rubber(-target) } else if target > maximum { target = maximum + rubber(target - maximum) }
        scroll = target
    }

    func endScrub(velocity: CGFloat) {
        scrollStart = nil
        let rest = layout.restingScroll(from: scroll, velocity: velocity, in: metrics)
        withAnimation(.smooth(duration: 0.45, extraBounce: 0.04)) { scroll = rest }
        // Focus follows the screen when it leaves the focused column behind.
        let visible = layout.visibleColumns(at: rest, in: metrics)
        if let focused = layout.focusedColumnIndex, !visible.contains(layout.columns[focused].id),
           let first = visible.first.flatMap(layout.column(id:))?.windows.first {
            memory.layout.focus(first)
            if let session, let remote = session.windows[first] { session.focus(remote) }
        }
        UISelectionFeedbackGenerator().selectionChanged()
        apply()
        save()
    }

    private func rubber(_ overshoot: CGFloat) -> CGFloat {
        let dimension = metrics.size.width
        return (1 - 1 / (overshoot * 0.55 / dimension + 1)) * dimension
    }

    /// Jumps to a column from the dock or Overview.
    func jump(to window: Int) {
        focus(window)
        overviewOpen = false
    }

    // MARK: Full screen

    /// Zooms a window to the workspace above the dock, keeping Desktop navigation.
    func zoom(_ window: Int) {
        guard layout.contains(window), coverWindow == nil else { return }
        focus(window, animated: false)
        coverProgress = 1
        zoomed = window
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.smooth(duration: 0.45, extraBounce: 0.06)) { coverProgress = 0 }
        apply()
    }

    func toggleZoom() {
        if let cover = coverWindow { pullBack(cover) } else if let focused = layout.focused { zoom(focused) }
    }

    /// Available from every tile, even if the app has not reported its fullscreen state.
    func exitAppFullscreen(_ window: Int) {
        guard let session, let remote = session.windows[window], let tile = contents[window] else { return }
        let scale = pixelsPerPoint
        let viewport = CGRect(x: tile.minX * scale, y: tile.minY * scale,
                              width: tile.width * scale, height: tile.height * scale).integral
        guard let target = WindowSizePolicy.fitting(viewport, minimum: remote.minimumSize,
            maximum: remote.maximumSize, fullscreen: false) else { return }
        session.exitFullscreen(remote, frame: target)
        zoomed = nil
        coverProgress = 0
        sent[window] = target
        apply()
    }

    /// The covering window followed back toward its tile by a finger, 0...1.
    func dragCover(progress: CGFloat) {
        coverProgress = min(1, max(0, progress))
    }

    /// Lets go of the covering window: far enough (or flicked), it settles into its tile;
    /// otherwise it springs back to the whole screen.
    func releaseCover(velocity: CGFloat) {
        guard let cover = coverWindow else { return }
        if coverProgress > 0.22 || velocity > 600 {
            pullBack(cover)
        } else {
            withAnimation(.smooth(duration: 0.35, extraBounce: 0.12)) { coverProgress = 0 }
        }
    }

    /// Puts the covering window back in its tile.
    private func pullBack(_ window: Int) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        withAnimation(.smooth(duration: 0.42, extraBounce: 0.04)) {
            coverProgress = 1
        } completion: { [weak self] in
            guard let self else { return }
            self.zoomed = nil
            self.coverProgress = 0
            if let session = self.session, let remote = session.windows[window], remote.isFullscreen, let tile = self.contents[window] {
                // The app asked for full screen; it is told it has left it.
                let scale = self.pixelsPerPoint
                let target = CGRect(x: tile.minX * scale, y: tile.minY * scale, width: tile.width * scale, height: tile.height * scale).integral
                self.sent[window] = target
                session.exitFullscreen(remote, frame: target)
            }
            self.apply()
        }
    }

    // MARK: Closing

    func close(_ window: Int, file: StaticString = #fileID, line: UInt = #line) {
        guard let session, let remote = session.windows[window] else { return }
        session.closeDiagnosed(remote, context: .init(overviewOpen: overviewOpen), file: file, line: line)
    }

    // MARK: Saving

    /// After any change the person made: the new geometry goes to Linux and the layout is kept.
    private func committed() {
        apply()
        save()
    }

    private(set) var appClassOf: (Int) -> String? = { _ in nil }

    func learnAppClasses(_ lookup: @escaping (Int) -> String?) { appClassOf = lookup }

    private func save() {
        guard let storageKey else { return }
        memory.learnWidths(appClass: appClassOf)
        if let data = memory.encoded() { UserDefaults.standard.set(data, forKey: storageKey) }
    }
}
