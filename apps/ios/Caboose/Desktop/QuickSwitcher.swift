import CabooseKit
import GameController
import SwiftUI

/// ⌥Tab: the windows in a strip down the desktop's leading edge, most recently used first.
///
/// Each Tab moves the selection (⇧ back), and the desktop shows the selected window as it
/// goes: Switchyard slides along its track to it, the floating desktop brings it to the
/// front. Letting go of ⌥ goes to it; Escape stays where you were. A tap on a window in the
/// strip goes to it too. iPadOS keeps ⌘Tab for its own app switcher, so this is ⌥Tab, the
/// Alt+Tab of Linux desktops.
@MainActor @Observable
final class QuickSwitcher {
    /// What the desktop that opened the strip does with its selection.
    struct Desktop {
        /// Show the window without giving it the keyboard.
        let preview: (Int) -> Void
        /// Go to the window.
        let commit: (Int) -> Void
        /// Put things back as they were.
        let cancel: () -> Void
    }

    private(set) var state = QuickSwitch()
    private var desktop: Desktop?

    /// ⌥Tab, or ⇧⌥Tab: opens the strip on `recent` (most recent first), or moves along it.
    func press(recent: [Int], reverse: Bool, desktop: Desktop) {
        if state.isOpen {
            state.advance(reverse: reverse)
        } else {
            state.open(recent, reverse: reverse)
            guard state.isOpen else { return }
            self.desktop = desktop
            watchOption()
        }
        if let selection = state.selection { self.desktop?.preview(selection) }
        UISelectionFeedbackGenerator().selectionChanged()
        // Without a way to see ⌥ let go, each press goes straight to its window.
        if !optionHeld { commit() }
    }

    func choose(_ window: Int) {
        state.select(window)
        commit()
    }

    func commit() {
        let desktop = desktop
        stop()
        if let window = state.close() { desktop?.commit(window) }
    }

    func cancel() {
        let desktop = desktop
        stop()
        state.close()
        desktop?.cancel()
    }

    /// Windows that closed while the strip is open leave it.
    func prune(keeping live: Set<Int>) {
        guard state.isOpen else { return }
        state.prune(keeping: live)
        if !state.isOpen { cancel() } else if let selection = state.selection { desktop?.preview(selection) }
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
                    guard let self, self.state.isOpen, !self.optionHeld else { return }
                    self.commit()
                }
            }
        }
    }

    private func stop() {
        for key in optionKeys { key.pressedChangedHandler = nil }
        desktop = nil
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
struct QuickSwitchStrip: View {
    @Environment(AppModel.self) private var model
    /// The height the strip has, in points.
    let height: CGFloat

    var body: some View {
        let switcher = model.quickSwitch
        let windows = model.session?.windows ?? [:]
        if switcher.state.isOpen {
            let strip = switcher.state.strip(height: height - 24)
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
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .transition(.move(edge: .leading).combined(with: .opacity))
            .onChange(of: Set(windows.keys)) { _, live in switcher.prune(keeping: live) }
        }
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
}
