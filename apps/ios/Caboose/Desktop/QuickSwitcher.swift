import CabooseKit
import GameController
import SwiftUI

/// Quick Switch: the windows in a strip down the desktop's leading edge, most recently used
/// first, with the selected one's app and title beside it.
///
/// - **Keys.** ⌥Tab opens it on the window before the current one; each Tab moves on (⇧
///   back), letting go of ⌥ goes to the selection and Escape stays. iPadOS keeps ⌘Tab for its
///   own app switcher, so this is the Alt+Tab of Linux desktops.
/// - **Hold.** Holding the dock's Overview (Switchyard) or Launchpad (the floating desktop)
///   opens it with nothing selected; sliding the finger up selects the window level with it,
///   and letting go there goes to it. Letting go anywhere else stays.
/// - **Choose.** VoiceOver's Switch Windows action, or a secondary click on Launchpad, opens it
///   to be tapped or clicked, with Stay Here.
///
/// While it is open the desktop shows the selection without telling Linux anything: no
/// window is configured, moved or resized until the switch lands. It lands only on a window
/// that still exists in the same ready session, and it is cancelled when the desktop that
/// opened it goes away, a window is shown as a card, the app leaves the foreground, or the
/// session changes.
@MainActor @Observable
final class QuickSwitcher {
    /// The desktop the strip belongs to. A device shows one at a time; a TV's desktop and the
    /// phone driving it are both `.desktop`.
    enum Owner: Hashable { case yard, desktop }

    enum Mode { case keys, hold, choose }

    /// What the desktop that opened the strip does with its selection.
    struct Desktop {
        let owner: Owner
        /// The session the windows belong to; the switch lands only in it.
        weak var session: AnyObject?
        /// Show the window without giving it the keyboard or changing its geometry.
        let preview: (Int) -> Void
        /// Go to the window.
        let commit: (Int) -> Void
        /// Put things back as they were.
        let cancel: () -> Void
    }

    private(set) var state = QuickSwitch()
    private(set) var mode = Mode.keys
    private var desktop: Desktop?
    var owner: Owner? { state.isOpen ? desktop?.owner : nil }

    /// Each shown window's row, in the coordinate space its owner tracks fingers and the
    /// pointer in, and Stay Here's.
    @ObservationIgnored var rowFrames: [Int: CGRect] = [:]
    @ObservationIgnored var stayFrame: CGRect?
    /// When a hold last ended, so the dock's own swipe-up does not also open Overview.
    @ObservationIgnored private(set) var holdEnded = Date.distantPast

    // MARK: Opening

    /// ⌥Tab, or ⇧⌥Tab: opens the strip on `recent` (most recent first), or moves along it.
    func press(recent: [Int], reverse: Bool, desktop: Desktop) {
        if state.isOpen, self.desktop?.owner == desktop.owner, mode != .hold {
            state.advance(reverse: reverse)
            mode = .keys
        } else {
            begin(desktop)
            state.open(recent, reverse: reverse)
            guard state.isOpen else { return end() }
            mode = .keys
            watchOption()
        }
        previewSelection()
        UISelectionFeedbackGenerator().selectionChanged()
        // Without a way to see ⌥ let go, each press goes straight to its window.
        if !optionHeld { commit() }
    }

    /// A finger held on the dock: open with nothing selected, for `track` and `release`.
    func hold(recent: [Int], desktop: Desktop) {
        begin(desktop)
        state.present(recent)
        guard state.isOpen else { return end() }
        mode = .hold
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Opens to be chosen from by a tap, a click or VoiceOver, with Stay Here.
    func present(recent: [Int], desktop: Desktop) {
        begin(desktop)
        state.present(recent)
        guard state.isOpen else { return end() }
        mode = .choose
    }

    private func begin(_ desktop: Desktop) {
        if state.isOpen { cancel() }
        rowFrames = [:]
        stayFrame = nil
        self.desktop = desktop
    }

    // MARK: Moving

    /// The held finger is at `point`, in the owner's space: the window level with it is
    /// selected, each row answering across half the gap either side; elsewhere, none.
    func track(_ point: CGPoint) {
        guard state.isOpen, mode == .hold else { return }
        let row = rowFrames.first { point.y >= $0.value.minY - 4 && point.y < $0.value.maxY + 4 }?.key
        guard row != state.selection else { return }
        if let row { state.select(row) } else { state.deselect() }
        previewSelection()
        if row != nil { UISelectionFeedbackGenerator().selectionChanged() }
    }

    /// The held finger let go: to the selection, or nowhere.
    func release() {
        guard state.isOpen, mode == .hold else { return }
        holdEnded = Date()
        if state.selection != nil { commit() } else { cancel() }
    }

    /// The window under the pointer, in the owner's space, if the strip takes clicks there.
    func item(at point: CGPoint) -> Int? {
        guard state.isOpen, mode != .hold else { return nil }
        return rowFrames.first { $0.value.contains(point) }?.key
    }

    func staysAt(_ point: CGPoint) -> Bool {
        state.isOpen && mode == .choose && stayFrame?.contains(point) == true
    }

    func choose(_ window: Int) {
        guard state.isOpen else { return }
        state.select(window)
        commit()
    }

    private func previewSelection() {
        guard let desktop else { return }
        if let selection = state.selection, live(selection, in: desktop) { desktop.preview(selection) } else { desktop.cancel() }
    }

    // MARK: Landing

    func commit() {
        let desktop = desktop
        let window = state.close()
        end()
        guard let desktop else { return }
        guard let window, live(window, in: desktop) else { return desktop.cancel() }
        desktop.commit(window)
    }

    private func live(_ window: Int, in desktop: Desktop) -> Bool {
        guard let session = desktop.session as? any DisplaySession, case .ready = session.state else { return false }
        return session.windows[window] != nil
    }

    func cancel() {
        let desktop = desktop
        state.close()
        end()
        desktop?.cancel()
    }

    /// Cancels the strip if `owner`'s desktop opened it.
    func cancel(owner: Owner) {
        if self.owner == owner { cancel() }
    }

    /// Windows that closed while the strip is open leave it.
    func prune(keeping live: Set<Int>) {
        guard state.isOpen else { return }
        state.prune(keeping: live)
        rowFrames = rowFrames.filter { live.contains($0.key) }
        if !state.isOpen { cancel() } else { previewSelection() }
    }

    private func end() {
        for key in optionKeys { key.pressedChangedHandler = nil }
        desktop = nil
        mode = .keys
        rowFrames = [:]
        stayFrame = nil
    }

    // MARK: ⌥

    private var optionKeys: [GCControllerButtonInput] {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return [] }
        return [GCKeyCode.leftAlt, .rightAlt].compactMap { input.button(forKeyCode: $0) }
    }

    private var optionHeld: Bool { optionKeys.contains { $0.isPressed } }

    private func watchOption() {
        for key in optionKeys {
            key.pressedChangedHandler = { [weak self] _, _, _ in
                Task { @MainActor in
                    guard let self, self.state.isOpen, self.mode == .keys, !self.optionHeld else { return }
                    self.commit()
                }
            }
        }
    }
}

/// The ⌥Tab keys, for the desktop on this screen and for the phone driving a TV. Escape
/// cancels only while the strip is open, so it otherwise reaches the app.
struct QuickSwitchKeys: View {
    @Environment(AppModel.self) private var model
    let recent: () -> [Int]
    let desktop: () -> QuickSwitcher.Desktop

    var body: some View {
        let switcher = model.quickSwitch
        Group {
            Button("Switch Windows") { switcher.press(recent: recent(), reverse: false, desktop: desktop()) }
                .keyboardShortcut(.tab, modifiers: .option)
            Button("Switch Windows Back") { switcher.press(recent: recent(), reverse: true, desktop: desktop()) }
                .keyboardShortcut(.tab, modifiers: [.option, .shift])
            if switcher.state.isOpen {
                Button("Stay Here") { switcher.cancel() }.keyboardShortcut(.escape, modifiers: .option)
                Button("Stay Here") { switcher.cancel() }.keyboardShortcut(.escape, modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The strip itself: a column of the windows' app icons in glass at the leading edge,
/// vertically centred, the selected one on a lit plate with its app and title beside it.
/// It is drawn only for the desktop that opened it, and cancels that desktop's switch when
/// it leaves the screen, a card covers it, the app goes to the background or the session
/// changes.
struct QuickSwitchStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let owner: QuickSwitcher.Owner
    /// The height the strip has, in points.
    let height: CGFloat
    /// Where the owner tracks the finger or pointer that chooses a row.
    let space: CoordinateSpace
    /// Rows take taps themselves. A desktop that routes every touch and click through its own
    /// hit-testing (the floating desktop, a TV) selects through `QuickSwitcher.item(at:)`.
    var tappable = true

    var body: some View {
        let switcher = model.quickSwitch
        let windows = model.session?.windows ?? [:]
        ZStack(alignment: .topLeading) {
            if switcher.owner == owner {
                strip(switcher, windows: windows)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { switcher.cancel(owner: owner) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { switcher.cancel(owner: owner) } }
        .onChange(of: model.presentedWindowID) { _, card in if card != nil { switcher.cancel(owner: owner) } }
        .onChange(of: model.session.map { ObjectIdentifier($0) }) { _, _ in switcher.cancel(owner: owner) }
        .onChange(of: Set(windows.keys)) { _, live in if switcher.owner == owner { switcher.prune(keeping: live) } }
    }

    @ViewBuilder private func strip(_ switcher: QuickSwitcher, windows: [Int: RemoteWindow]) -> some View {
        let strip = switcher.state.strip(height: height - 24 - (switcher.mode == .choose ? 52 : 0))
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .frame(width: strip.size.width, height: strip.size.height)
                ForEach(Array(strip.visible), id: \.self) { index in
                    let id = switcher.state.windows[index]
                    if let frame = strip.frame(of: index), let window = windows[id] {
                        item(window, selected: id == switcher.state.selection, size: strip.item)
                            .frame(width: frame.width, height: frame.height)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: space) } action: { switcher.rowFrames[id] = $0 }
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                if let selection = switcher.state.selection, let index = switcher.state.windows.firstIndex(of: selection),
                   let frame = strip.frame(of: index), let window = windows[selection] {
                    label(window)
                        .fixedSize()
                        .alignmentGuide(.leading) { _ in -(strip.size.width + 10) }
                        .alignmentGuide(.top) { dimensions in -(frame.midY - dimensions.height / 2) }
                }
            }
            if switcher.mode == .choose {
                Button { switcher.cancel() } label: {
                    Label("Stay Here", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: strip.size.width, height: 44)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .allowsHitTesting(tappable)
                .accessibilityLabel("Stay Here")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: space) } action: { switcher.stayFrame = $0 }
            }
        }
        .padding(.leading, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private func item(_ window: RemoteWindow, selected: Bool, size: CGFloat) -> some View {
        Button { model.quickSwitch.choose(window.id) } label: {
            Group {
                if let icon = model.icon(for: window) {
                    Image(uiImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "macwindow").font(.system(size: size * 0.45)).foregroundStyle(.white)
                }
            }
            .padding(size * 0.12)
            .frame(width: size, height: size)
            .background(.white.opacity(selected ? 0.22 : 0), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .scaleEffect(selected ? 1 : 0.92)
            .animation(.snappy(duration: 0.18), value: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(tappable && model.quickSwitch.mode != .hold)
        .accessibilityLabel("\(model.appName(for: window)), \(window.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func label(_ window: RemoteWindow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(model.appName(for: window)).font(.callout.weight(.semibold))
            if !window.title.isEmpty {
                Text(window.title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension AppModel {
    /// The name of a window's app, as the computer lists it, else its window class.
    func appName(for window: RemoteWindow) -> String {
        apps.first { matches(window, $0) }?.name ?? window.appClass?.name ?? "Window"
    }

    /// Application windows, most recently used first, for Quick Switch.
    var recentWindowIDs: [Int] { appWindows.map(\.id) }
}
