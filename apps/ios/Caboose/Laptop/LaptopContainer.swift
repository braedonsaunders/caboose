import CabooseKit
import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var laptopInputOwned = false
}

struct LaptopModeMenu: View {
    @AppStorage("caboose.laptop.mode") private var mode = LaptopLayout.Mode.automatic.rawValue
    var body: some View {
        Menu {
            Picker("Screen layout", selection: $mode) {
                Text("Automatic").tag(LaptopLayout.Mode.automatic.rawValue)
                Text("Tablet").tag(LaptopLayout.Mode.tablet.rawValue)
                Text("Laptop").tag(LaptopLayout.Mode.laptop.rawValue)
            }
        } label: {
            Label("Screen layout", systemImage: "laptopcomputer")
        }
    }
}

/// Keeps a single upper surface mounted as the fold, keyboard and controls change.
/// The native keyboard and the existing KeyBar belong to the lower trackpad responder.
struct LaptopContainer<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.toolbarVerticalEdgeIfAvailable) private var barEdge
    @Environment(\.shellTabPlacement) private var tabPlacement
    @State private var layoutActive = false
    @AppStorage("caboose.laptop.mode") private var mode = LaptopLayout.Mode.automatic.rawValue
    @State private var geometry = LaptopGeometry()
    /// The system keyboard, which only the custom keyboard's globe key opens, for emoji,
    /// dictation and other languages. It covers the controls while it shows.
    @State private var systemKeyboard = false
    let isCard: Bool
    let content: (Bool) -> Content
    var activeChanged: (Bool) -> Void

    init(isCard: Bool = false, activeChanged: @escaping (Bool) -> Void = { _ in }, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.isCard = isCard; self.content = content; self.activeChanged = activeChanged
    }

    var body: some View {
        GeometryReader { proxy in
            let active = LaptopLayout.isActive(mode: LaptopLayout.Mode(rawValue: mode) ?? .automatic,
                                               size: proxy.size, division: geometry.division,
                                               partiallyOpen: geometry.partiallyOpen)
            let frames = LaptopLayout.frames(size: proxy.size, division: geometry.division, keyboard: geometry.keyboard)
            ZStack(alignment: .topLeading) {
                content(active)
                    .environment(\.laptopInputOwned, active)
                    // In Tablet, the shell has already proposed the area above the keyboard.
                    // Subtracting its measured height again collapses the app to its title bar.
                    .frame(width: proxy.size.width, height: active ? frames.screen.height : proxy.size.height)
                    .clipped()
                if active {
                    VStack(spacing: 0) {
                        if !isCard && !model.externalDisplayActive {
                            Dock(desktop: model.desktop, compact: true, coordinateSpace: "laptop", interactive: true)
                                .frame(maxWidth: .infinity).frame(height: 44)
                        }
                    LaptopControls(compact: frames.controls.height < 280, isCard: isCard,
                                   enabled: scenePhase == .active && (isCard ? model.presentedWindowID != nil : model.presentedWindowID == nil && model.selectedTab == .desktop),
                                   systemKeyboard: $systemKeyboard)
                    }
                        .frame(width: frames.controls.width, height: max(1, frames.controls.height))
                        .clipped()
                        .offset(y: frames.controls.minY)
                }
            }
            .coordinateSpace(name: "laptop")
            .overlay(alignment: .topLeading) {
                if active && !isCard && !model.externalDisplayActive && model.desktop.showsCursor {
                    Cursor(hit: model.desktop.hovered, ui: model.desktop.ui)
                        .position(model.desktop.cursor).allowsHitTesting(false)
                }
            }
            .onChange(of: frames, initial: true) { _, frames in
                updatePointerArea(active: active, frames: frames)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .overlay(alignment: .bottomTrailing) {
                // The system keyboard has no header of its own here, so that nothing of it
                // lands on the other side of the fold; this brings Laptop's keyboard back.
                if active && systemKeyboard {
                    Button("Laptop Keyboard", systemImage: "keyboard.chevron.compact.down") {
                        systemKeyboard = false
                        model.keyboardVisible = false
                    }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 52, height: 44)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .padding(.trailing, 12)
                    .padding(.bottom, max(0, proxy.size.height - frames.screen.maxY) + 8)
                    .accessibilityHint("Closes the system keyboard")
                }
            }
            .background { LaptopGeometryProbe { geometry = $0 }.allowsHitTesting(false) }
            .onChange(of: active, initial: true) { _, value in
                layoutActive = value
                systemKeyboard = false
                activeChanged(value)
                if !isCard { model.setLaptopDesktop(value) }
                updatePointerArea(active: value, frames: frames)
                model.keyboardVisible = false
                LaptopPointer.shared.clear()
            }
            .onAppear {
                if !isCard { model.setLaptopDesktop(active) }
                updatePointerArea(active: active, frames: frames)
            }
            .onChange(of: ObjectIdentifier(model.desktop)) { _, _ in
                updatePointerArea(active: active, frames: frames)
            }
            .onDisappear {
                if !isCard { model.setLaptopDesktop(false) }
            }
        }
        // Safe-area expansion belongs to the measured parent, never a clipped child.
        // Both native and custom side rails reserve width, not height. Only Desktop
        // uses the custom rail; app cards retain their own toolbar safe areas.
        // Laptop owns the whole display and draws navigation below the hinge.
        .ignoresSafeArea(.container, edges: layoutActive ? .all : (barEdge != nil || (!isCard && tabPlacement == .sidebar) ? [.top, .bottom] : []))
        // Only the split layout owns keyboard avoidance. Tablet uses SwiftUI's proposal.
        .ignoresSafeArea(.keyboard, edges: layoutActive ? .bottom : [])
    }
    private func updatePointerArea(active: Bool, frames: LaptopLayout.Frames) {
        guard active, !isCard, !model.externalDisplayActive else { return }
        model.desktop.pointerArea = CGSize(width: frames.controls.width, height: frames.controls.minY + min(44, frames.controls.height))
    }

}

private struct LaptopControls: View {
    @Environment(AppModel.self) private var model
    @State private var input: LaptopLayout.Input = .trackpad
    @State private var surface = TrackpadSurface()
    @State private var gestureHelp = false
    let compact: Bool
    let isCard: Bool
    let enabled: Bool
    @Binding var systemKeyboard: Bool

    private var desktop: DesktopModel? { isCard ? nil : model.desktop }
    private var target: RemoteWindow? {
        guard isCard, let parent = model.window(model.presentedWindowID) else { return nil }
        return model.auxiliaryWindows(for: parent).last { !$0.isOverrideRedirect } ?? parent
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    // Keyboard mode keeps the trackpad mounted at no height: it is the
                    // responder the keyboard types through.
                    trackpad
                        .frame(height: LaptopLayout.trackpadHeight(input, available: proxy.size.height))
                        .clipped()
                    if input.showsKeyboard {
                        VStack(spacing: 0) {
                            LaptopKeyHeader(surface: surface).frame(maxWidth: .infinity).frame(height: 48)
                            LaptopComboKeyboard(onText: { surface.insertText($0) },
                                                onKey: { surface.performKeyboardAction(.key($0)) },
                                                onNativeKeyboard: openSystemKeyboard)
                        }
                        .background(Color(uiColor: .systemGray5))
                    }
                    if input == .gamepad {
                        // A card's target comes from the model, the desktop's front window from the
                        // desktop, so the panel sees either change as it happens.
                        GamepadPanel(target: { isCard ? target : surface.focusedWindow }, enabled: enabled)
                    }
                }
            }
            Divider()
            rail.frame(width: 56)
        }
        .background(input.showsKeyboard ? Color(uiColor: .systemGray5) : Color(white: 0.14))
        .allowsHitTesting(enabled)
        .sheet(isPresented: $gestureHelp) { TrackpadGestureGuide() }
        .onChange(of: model.keyboardVisible) { _, visible in
            if systemKeyboard {
                if !visible { closeSystemKeyboard() }
                return
            }
            guard visible else { return }
            // A text field wants the keyboard: Laptop's own answers, beside the trackpad
            // that focused the field. The system keyboard never opens by itself here.
            model.keyboardVisible = false
            if input == .trackpad { choose(.combo) }
        }
        .onChange(of: systemKeyboard) { _, open in
            if !open { closeSystemKeyboard() }
        }
    }

    private var trackpad: some View {
        Trackpad(desktop: desktop, target: target, keyboardVisible: systemKeyboard && model.keyboardVisible,
                 enabled: enabled, pointerEnabled: input == .trackpad || input == .combo,
                 sharedSurface: surface, inlineControls: input.showsKeyboard && !systemKeyboard,
                 bareSystemKeyboard: systemKeyboard,
                 dismissInline: { choose(.trackpad) })
            .background(Color(white: 0.12))
            .overlay {
                if input == .trackpad || input == .combo {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.draw").font(input == .combo ? .body : .title2)
                        Text("Trackpad").font(.subheadline.weight(.medium))
                        if input != .combo && !compact {
                            Text("Tap to click · two fingers to scroll or right-click").font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(8).allowsHitTesting(false)
                }
            }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            if compact {
                // The native keyboard can leave only one row above it. One anchored
                // control retains every action without clipping a second row.
                Menu {
                    inputChoices
                    Divider()
                    windowSwitcher
                    computerActions
                    navigationActions
                } label: { Image(systemName: Self.inputSymbol).frame(width: 48, height: 44) }
                .accessibilityLabel("Laptop controls")
                .accessibilityValue(input.title)
            } else {
                Menu { inputChoices } label: { Image(systemName: Self.inputSymbol).frame(width: 48, height: 44) }
                    .accessibilityLabel("Input")
                    .accessibilityValue(input.title)
                windowSwitcher
                Button("Computer", systemImage: "gearshape") { model.settingsPresented = true }
                    .frame(width: 48, height: 44)
                LifecycleMenu().frame(width: 48, height: 44)
                Menu { navigationActions } label: { Image(systemName: "ellipsis").frame(width: 48, height: 44) }
                    .accessibilityLabel("Laptop controls and navigation")
            }
            Spacer(minLength: 0)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
    }

    /// The input menu's one icon, the same in every mode; the menu marks the current mode.
    private static let inputSymbol = "switch.2"

    @ViewBuilder private var inputChoices: some View {
        Picker("Input", selection: Binding(get: { input }, set: { choose($0) })) {
            ForEach(LaptopLayout.Input.allCases, id: \.self) { choice in
                Label(choice.title, systemImage: choice.symbol).tag(choice)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Trackpad Gestures", systemImage: "hand.draw") { gestureHelp = true }
    }

    @ViewBuilder private var computerActions: some View {
        Button("Computer Settings", systemImage: "gearshape") { model.settingsPresented = true }
        Button("Park", systemImage: "moon.zzz") { Task { try? await model.parkComputer() } }
        if model.computerStatus?.capabilities.restart == true {
            Button("Restart…", systemImage: "arrow.clockwise", role: .destructive) { model.restartConfirmationPresented = true }
        }
    }

    @ViewBuilder private var navigationActions: some View {
        LaptopModeMenu()
        Button("Wallpaper", systemImage: "photo") { model.wallpaperPickerPresented = true }
        Divider()
        if isCard { Button("Desktop", systemImage: "macwindow") { leave(.desktop) } }
        Button("Home", systemImage: "house") { leave(.home) }
        Button("Agents", systemImage: "sparkles") { leave(.agents) }
        Button("Apps", systemImage: "square.grid.2x2") { leave(.apps) }
        if TerminalSlot.isFilled { Button("Terminal", systemImage: "apple.terminal") { leave(.terminal) } }
    }

    private var windowSwitcher: some View {
        Menu {
            ForEach(model.appWindows) { window in
                Button(window.title.isEmpty ? model.appName(for: window) : window.title) {
                    if isCard { model.presentedWindowID = window.id }
                    else { model.desktop.activate(window.id, session: model.session) }
                }
            }
        } label: { Image(systemName: "macwindow.on.rectangle").frame(width: 48, height: 44) }
        .accessibilityLabel("Switch window")
    }

    private func choose(_ value: LaptopLayout.Input) {
        surface.endInteraction()
        systemKeyboard = false
        surface.inlineKeyboardControls = value.showsKeyboard
        input = value
        model.keyboardVisible = false
    }

    /// The globe key: the system keyboard, for what Laptop's keyboard does not type.
    private func openSystemKeyboard() {
        systemKeyboard = true
        surface.inlineKeyboardControls = false
        model.keyboardVisible = true
    }

    private func closeSystemKeyboard() {
        systemKeyboard = false
        surface.inlineKeyboardControls = input.showsKeyboard
        if model.keyboardVisible { model.keyboardVisible = false }
    }
    private func leave(_ tab: ShellTab) {
        model.keyboardVisible = false
        model.presentedWindowID = nil
        model.selectedTab = tab
    }
}

/// The monitor remains the only host of the live desktop/video. This phone overview only
/// shows small still previews and focuses windows without resizing them on the monitor.
struct LaptopExternalOverview: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Desktop on your display", systemImage: "display").font(.headline)
            Text("Choose a window, then use the keyboard or trackpad below.")
                .font(.subheadline).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 16) {
                    ForEach(model.appWindows) { window in
                        Button { model.desktop.activate(window.id, session: model.session) } label: {
                            VStack(spacing: 8) {
                                RemoteWindowPreview(window: window).frame(width: 150, height: 100).clipped().clipShape(.rect(cornerRadius: 12))
                                Text(window.title.isEmpty ? model.appName(for: window) : window.title).font(.caption).lineLimit(1).frame(width: 150)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(16)
    }
}

struct LaptopGeometry: Equatable {
    var division: CGRect?
    var partiallyOpen = false
    var keyboard: CGFloat = 0
}

struct LaptopGeometryProbe: UIViewRepresentable {
    let changed: (LaptopGeometry) -> Void
    func makeUIView(context: Context) -> Probe { Probe(changed: changed) }
    func updateUIView(_ view: Probe, context: Context) { view.changed = changed; view.measure() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.stop() }

    final class Probe: UIView {
        var changed: (LaptopGeometry) -> Void
        private var partial = false
        private var keyboardFrame: CGRect?
        private var observers: [NSObjectProtocol] = []
        private var pending: DispatchWorkItem?
        private var previous = LaptopGeometry()

        init(changed: @escaping (LaptopGeometry) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
            if #available(iOS 27.1, *) {
                addInteraction(UIHingeInteraction { [weak self] _, update in
                    self?.partial = update.hinge?.status == .partiallyOpen
                    self?.measure(settling: true)
                })
            }
            for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        if let screen = note.object as? UIScreen, screen !== window.screen { return }
                        self.keyboardFrame = note.name == UIResponder.keyboardWillHideNotification ? nil :
                            (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
                        self.measure()
                    }
                })
            }
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func layoutSubviews() { super.layoutSubviews(); measure() }
        override func didMoveToWindow() { super.didMoveToWindow(); measure() }
        func stop() {
            pending?.cancel()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
        }
        func measure(settling: Bool = false) {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            var value = LaptopGeometry(partiallyOpen: partial)
            if #available(iOS 27.1, *) {
                value.division = reservedRegions(kind: .division).first { $0.frame.width > $0.frame.height }?.frame
            }
            if let keyboardFrame {
                let local = convert(keyboardFrame, from: window.screen.coordinateSpace)
                let overlap = bounds.intersection(local)
                // Floating keyboards don't reserve the full-width bottom control region.
                if !overlap.isNull, overlap.width >= bounds.width * 0.75, overlap.maxY >= bounds.maxY - 1 {
                    value.keyboard = overlap.height
                }
            }
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.window != nil, self.previous != value else { return }
                self.previous = value
                self.changed(value)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (settling ? 0.2 : 0), execute: work)
        }
    }
}

/// The text input's key bar, laid out at the width SwiftUI gives it. The bar is the same view
/// the system keyboard shows as its accessory elsewhere, so a host view owns its frame here.
private struct LaptopKeyHeader: UIViewRepresentable {
    let surface: TrackpadSurface
    func makeUIView(context: Context) -> Host { Host() }
    func updateUIView(_ host: Host, context: Context) { host.bar = surface.keyboardControls }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Host, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: 48)
    }

    final class Host: UIView {
        var bar: KeyBar? {
            didSet { if bar !== oldValue { setNeedsLayout() } }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let bar else { return }
            if bar.superview !== self {
                bar.removeFromSuperview()
                bar.translatesAutoresizingMaskIntoConstraints = true
                addSubview(bar)
            }
            bar.frame = bounds
        }
    }
}
