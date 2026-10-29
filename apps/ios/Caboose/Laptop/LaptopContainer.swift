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
    @State private var input: LaptopLayout.Input = .trackpad
    let isCard: Bool
    let content: (Bool) -> Content
    var activeChanged: (Bool) -> Void

    init(isCard: Bool = false, activeChanged: @escaping (Bool) -> Void = { _ in }, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.isCard = isCard; self.content = content; self.activeChanged = activeChanged
    }

    var body: some View {
        GeometryReader { proxy in
            let active = LaptopLayout.isActive(mode: LaptopLayout.Mode(rawValue: mode) ?? .automatic,
                                               size: geometry.hostSize ?? proxy.size, division: geometry.physicalDivision,
                                               partiallyOpen: geometry.partiallyOpen)
            let frames = LaptopLayout.frames(size: proxy.size, division: geometry.division, keyboard: geometry.keyboard)
            let physicalPanel = active ? geometry.hostSize.map {
                LaptopLayout.frames(size: $0, division: geometry.physicalDivision, keyboard: 0).screen.size
            } : nil
            ZStack(alignment: .topLeading) {
                LaptopUpperPanel(screen: frames.screen, division: geometry.division,
                                 active: active, size: proxy.size,
                                 fullscreen: !isCard && !model.externalDisplayActive && model.session.map {
                                     model.desktop.fullscreenWindow(in: $0.windows) != nil
                                 } == true) {
                    content(active)
                        .environment(\.laptopInputOwned, active)
                }
                if active {
                    VStack(spacing: 0) {
                        if !isCard && !model.externalDisplayActive {
                            Dock(desktop: model.desktop, compact: true, coordinateSpace: "laptop", interactive: true)
                                .frame(maxWidth: .infinity).frame(height: 44)
                        }
                    InputControls(placement: .laptop(compact: frames.controls.height < 280), isCard: isCard,
                                  enabled: scenePhase == .active && (isCard ? model.presentedWindowID != nil : model.presentedWindowID == nil && model.selectedTab == .desktop),
                                  input: $input, systemKeyboard: $systemKeyboard)
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
            .onChange(of: physicalPanel, initial: true) { _, panel in
                if !isCard { model.laptopPhysicalPanelChanged(to: panel) }
            }
            // Binding another computer clears its transient monitor mode even when
            // this physical panel remains mounted at exactly the same size.
            .onChange(of: model.credentials?.fileDomainIdentifier) { _, _ in
                if !isCard { model.laptopPhysicalPanelChanged(to: physicalPanel) }
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
                if !isCard {
                    model.setLaptopDesktop(active)
                    model.laptopPhysicalPanelChanged(to: physicalPanel)
                }
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

/// The monitor remains the only host of the live desktop/video. This phone overview only
/// shows small still previews and focuses windows without resizing them on the monitor.
struct LaptopExternalOverview: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Desktop on your display", systemImage: "display").font(.headline)
            Text("Choose a window, then use the trackpad, keyboard or controller below.")
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
    var hostSize: CGSize?
    var physicalDivision: CGRect?
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
        func physicalGeometry(division: CGRect?) -> LaptopGeometry {
            guard let window else { return LaptopGeometry() }
            return LaptopGeometry(division: division, hostSize: window.bounds.size,
                physicalDivision: division.map {
                    convert($0, to: window).offsetBy(dx: -window.bounds.minX, dy: -window.bounds.minY)
                })
        }

        func measure(settling: Bool = false) {
            guard let window, bounds.width > 0, bounds.height > 0 else { return }
            // Measure the actual attached scene window, independent of the proposed
            // SwiftUI viewport and keyboard. Convert reserved regions out of probe space.
            var division: CGRect?
            if #available(iOS 27.1, *) {
                division = reservedRegions(kind: .division).first { $0.frame.width > $0.frame.height }?.frame
            }
            var value = physicalGeometry(division: division)
            value.partiallyOpen = partial
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
struct LaptopKeyHeader: UIViewRepresentable {
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

/// Content ends at the upper edge of the physical division. Only that reserved
/// division gets a fullscreen matte; keyboard occlusion never becomes hinge padding.
struct LaptopUpperPanel<Content: View>: View {
    let screen: CGRect
    let division: CGRect?
    let active: Bool
    let size: CGSize
    let fullscreen: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Tablet already receives the shell's keyboard-adjusted proposal.
            content()
                .frame(width: size.width, height: active ? screen.height : size.height)
                .clipped()
            if active, fullscreen, let division,
               division.width > division.height, division.minY > 0, division.maxY < size.height {
                Color.black
                    .frame(width: size.width, height: division.height)
                    .offset(y: division.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: active ? max(screen.maxY, division?.maxY ?? screen.maxY) : size.height,
               alignment: .topLeading)
    }
}
