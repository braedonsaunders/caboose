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
    @AppStorage("caboose.laptop.mode") private var mode = LaptopLayout.Mode.automatic.rawValue
    @State private var geometry = LaptopGeometry()
    let isCard: Bool
    let content: (Bool) -> Content

    init(isCard: Bool = false, @ViewBuilder content: @escaping (Bool) -> Content) {
        self.isCard = isCard; self.content = content
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
                    .frame(width: proxy.size.width, height: active ? frames.screen.height : max(0, proxy.size.height - geometry.keyboard))
                    .clipped()
                if active {
                    LaptopControls(compact: frames.controls.height < 110, isCard: isCard,
                                   enabled: scenePhase == .active && (isCard ? model.presentedWindowID != nil : model.presentedWindowID == nil && model.selectedTab == .desktop))
                        .frame(width: frames.controls.width, height: max(1, frames.controls.height))
                        .clipped()
                        .offset(y: frames.controls.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background { LaptopGeometryProbe { geometry = $0 }.allowsHitTesting(false) }
            .onChange(of: active) { _, _ in
                // Do not leave a keyboard attached to a responder in the old control region.
                model.keyboardVisible = false
                LaptopPointer.shared.clear()
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct LaptopControls: View {
    @Environment(AppModel.self) private var model
    let compact: Bool
    let isCard: Bool
    let enabled: Bool

    private var desktop: DesktopModel? {
        guard !isCard else { return nil }
        return model.externalDisplayActive || model.deviceDesktopStyle == .free ? model.desktop : nil
    }
    private var target: RemoteWindow? {
        if isCard, let parent = model.window(model.presentedWindowID) {
            return model.auxiliaryWindows(for: parent).last { !$0.isOverrideRedirect } ?? parent
        }
        return model.window(model.yard.keyTarget(in: model.session?.windows ?? [:]))
    }

    var body: some View {
        VStack(spacing: 8) {
            if !compact {
                HStack(spacing: 12) {
                    Label(model.externalDisplayActive ? "Control Desk" : "Laptop", systemImage: model.externalDisplayActive ? "display" : "laptopcomputer")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(model.appWindows) { window in
                            Button(window.title.isEmpty ? model.appName(for: window) : window.title) {
                                if let desktop { desktop.activate(window.id, session: model.session) }
                                else if model.presentedWindowID != nil { model.presentedWindowID = window.id }
                                else { model.yard.focus(window.id) }
                            }
                        }
                    } label: { Image(systemName: "macwindow.on.rectangle").frame(width: 44, height: 44) }
                    .accessibilityLabel("Switch window")
                    Button { model.keyboardVisible.toggle() } label: {
                        Image(systemName: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(model.keyboardVisible ? "Hide Keyboard" : "Type")
                }
                .padding(.horizontal, 12)
            }
            Trackpad(desktop: desktop, target: desktop == nil ? target : nil, keyboardVisible: model.keyboardVisible, enabled: enabled)
                .clipShape(.rect(cornerRadius: 20))
                .overlay {
                    if !compact && !model.keyboardVisible {
                        VStack(spacing: 8) {
                            Image(systemName: "hand.draw").font(.title2)
                            Text("Trackpad").font(.subheadline.weight(.medium))
                            Text("Tap to click · two fingers to scroll or right-click")
                                .font(.caption).multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.secondary).padding().allowsHitTesting(false)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.12)).allowsHitTesting(false) }
        }
        .padding(compact ? 0 : 10)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 26))
        .allowsHitTesting(enabled)
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

private struct LaptopGeometry: Equatable {
    var division: CGRect?
    var partiallyOpen = false
    var keyboard: CGFloat = 0
}

private struct LaptopGeometryProbe: UIViewRepresentable {
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
