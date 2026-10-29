import CabooseKit
import GameController
import SwiftUI

/// A real shell on the computer, drawn natively: `TerminalModel` keeps the session, and
/// `CabooseTerminalView` (SwiftTerm) renders it. The screen is the tab's content; the shell
/// around it supplies the navigation stack, the wallpaper and its own toolbar items, and this
/// adds the session menu. Like Desktop, the grid fills the space beside a vertical sidebar.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.shellTabPlacement) private var placement
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.toolbarVerticalEdgeIfAvailable) private var barEdge
    @State private var terminal = TerminalModel.shared
    @State private var onScreen = false
    @State private var laptopActive = false

    /// The terminal needs the computer, not its display: it wakes the computer itself, and
    /// runs while the display is connecting, has failed or shows on another device. Only a
    /// computer the owner parked or is restarting shows its state instead.
    private var computerAvailable: Bool {
        switch model.phase {
        case .parked, .restarting, .needsSetup: false
        case .waking, .connecting, .ready, .failed, .displayElsewhere: true
        }
    }

    var body: some View {
        Group {
            if computerAvailable {
                TerminalWorkspace(terminal: terminal, activeChanged: {
                    laptopActive = $0
                    model.terminalLaptopActive = $0
                })
                    .background {
                        // One background covers the grid and inset; the renderer is clear.
                        Color(uiColor: TerminalTheme.background).opacity(TerminalTheme.backgroundOpacity)
                    }
                    .ignoresSafeArea(.container, edges: terminalEdges)
                    .overlay(alignment: .bottom) { TerminalStatusBar(terminal: terminal) }
                    .onAppear { onScreen = true; terminal.view.resignFirstResponder(); attach() }
                    .onDisappear { onScreen = false; terminal.hide() }
            } else {
                ComputerStateView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(terminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            if computerAvailable && !laptopActive { ToolbarItem(placement: .topBarTrailing) { sessionMenu } }
        }
        .toolbarVisibility(laptopActive || placement == .sidebar ? .hidden : .automatic, for: .navigationBar)
            .shellRailActions { if computerAvailable && !laptopActive { sessionMenu } }
        .keepsTabBarInVerticalBar()
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: if onScreen, computerAvailable { attach() }
            case .background: terminal.hide()
            default: break
            }
        }
        .onChange(of: model.host?.baseURL) { _, _ in if onScreen, computerAvailable { attach() } }
    }

    private var terminalEdges: Edge.Set {
        switch barEdge {
        case .trailing: [.top, .bottom, .leading]
        case .leading: [.top, .bottom, .trailing]
        case nil: []
        }
    }

    private func attach() {
        terminal.show(host: model.host)
        if GCKeyboard.coalesced != nil {
            DispatchQueue.main.async {
                guard onScreen, computerAvailable, GCKeyboard.coalesced != nil else { return }
                _ = terminal.view.becomeFirstResponder()
            }
        }
    }

    private var sessionMenu: some View { TerminalSessionsButton(terminal: terminal) }
}

private struct TerminalSessionsButton: View {
    let terminal: TerminalModel
    @State private var presented = false
    var body: some View {
        Button {
            presented = true
            Task { await terminal.refreshSessions() }
        } label: { Label("Sessions", systemImage: "terminal") }
        .confirmationDialog("Terminal", isPresented: $presented, titleVisibility: .visible) {
            Button("New Session") { terminal.newSession() }
            ForEach(terminal.sessions) { session in
                Button(session.displayName + (session.id == terminal.sessionID ? " ✓" : "")) { terminal.open(session) }
            }
            Button("Larger Text") { terminal.adjustTextSize(by: 1) }
            Button("Smaller Text") { terminal.adjustTextSize(by: -1) }
            if terminal.sessionID != nil {
                Button("Close Session", role: .destructive) { terminal.closeSession() }
            }
        }
    }
}

/// Uses the same fold geometry and keyboard components as Desktop, with terminal byte semantics.
private struct TerminalWorkspace: View {
    let terminal: TerminalModel
    var activeChanged: (Bool) -> Void
    @AppStorage("caboose.laptop.mode") private var mode = LaptopLayout.Mode.automatic.rawValue
    @State private var geometry = LaptopGeometry()
    @State private var keyboardHidden = false
    @State private var layoutActive = false
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            let active = LaptopLayout.isActive(mode: LaptopLayout.Mode(rawValue: mode) ?? .automatic,
                                               size: proxy.size, division: geometry.division,
                                               partiallyOpen: geometry.partiallyOpen)
            let frames = LaptopLayout.frames(size: proxy.size, division: geometry.division, keyboard: geometry.keyboard)
            ZStack(alignment: .topLeading) {
                TerminalSurface(view: terminal.view)
                    .padding(10)
                    .frame(width: proxy.size.width, height: active ? frames.screen.height : proxy.size.height)
                    .clipped()
                if active && geometry.keyboard == 0 {
                    VStack(spacing: 0) {
                        HStack {
                            TerminalSessionsButton(terminal: terminal)
                            Spacer(minLength: 8)
                            Text(terminal.title).font(.caption).lineLimit(1)
                            Spacer(minLength: 8)
                            LaptopModeMenu().labelStyle(.iconOnly)
                            Menu {
                                Button("Home", systemImage: "house") { model.selectedTab = .home }
                                Button("Desktop", systemImage: "macwindow") { model.selectedTab = .desktop }
                                Button("Agents", systemImage: "sparkles") { model.selectedTab = .agents }
                                Button("Apps", systemImage: "square.grid.2x2") { model.selectedTab = .apps }
                                Divider()
                                Button("Computer Settings", systemImage: "gearshape") { model.settingsPresented = true }
                                ComputerLifecycleActions()
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("Terminal navigation and computer controls")
                        }
                        .padding(.horizontal, 12).frame(height: 44)
                        if keyboardHidden {
                            Button { keyboardHidden = false } label: {
                                Label("Show Keyboard", systemImage: "keyboard")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            TerminalInlineHeader(view: terminal.view, dismiss: { keyboardHidden = true })
                                .frame(height: 48)
                            LaptopComboKeyboard(onText: { terminal.view.insertText($0) }, onKey: { key in
                                if key == "BackSpace" { terminal.view.deleteBackward() }
                                else if key == "Return" { terminal.view.insertText("\n") }
                            }, onNativeKeyboard: {
                                terminal.view.becomeFirstResponder()
                            })
                        }
                    }
                    .background(Color(uiColor: .systemGray5))
                    .frame(width: frames.controls.width, height: frames.controls.height)
                    .clipped()
                    .offset(y: frames.controls.minY)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .background { LaptopGeometryProbe { geometry = $0 }.allowsHitTesting(false) }
            .onChange(of: active, initial: true) { _, value in
                layoutActive = value
                activeChanged(value)
                terminal.view.resignFirstResponder()
            }
        }
        .ignoresSafeArea(.container, edges: layoutActive ? .all : [])
        .ignoresSafeArea(.keyboard, edges: layoutActive ? .bottom : [])
        .onAppear {
            activeChanged(layoutActive)
            terminal.view.onKeyboardDismiss = { keyboardHidden = true }
        }
        .onDisappear {
            activeChanged(false)
            terminal.view.onKeyboardDismiss = nil
        }
    }
}

private struct TerminalInlineHeader: UIViewRepresentable {
    let view: CabooseTerminalView
    var dismiss: () -> Void
    func makeCoordinator() -> TerminalKeyRow { TerminalKeyRow() }
    func makeUIView(context: Context) -> KeyBar { context.coordinator.view }
    func updateUIView(_ bar: KeyBar, context: Context) {
        view.inlineKeyRow = context.coordinator
        context.coordinator.onAction = { [weak view] action in
            if case .dismissKeyboard = action { dismiss() }
            else { view?.keyRowAction(action) }
        }
        context.coordinator.show(control: view.controlModifier, alt: view.metaModifier)
    }
}

/// Hosts the long-lived terminal view, which moves into each new container as the tab is rebuilt.
struct TerminalSurface: UIViewRepresentable {
    let view: CabooseTerminalView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        mount(in: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // A shell placement change can reuse this representable after another container
        // temporarily hosted the long-lived view. Reclaim it on update, not just creation.
        mount(in: container)
    }

    private func mount(in container: UIView) {
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view.setNeedsLayout()
        view.setNeedsDisplay()
    }

    static func dismantleUIView(_ container: UIView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// What the session is doing when it is not simply live, with the one action that helps.
private struct TerminalStatusBar: View {
    let terminal: TerminalModel

    var body: some View {
        Group {
            switch terminal.status {
            case .live:
                EmptyView()
            case .starting:
                bar { ProgressView().controlSize(.small); Text("Starting a shell…") }
            case .reconnecting:
                bar { ProgressView().controlSize(.small); Text("Reconnecting…") }
            case .exited(let how):
                bar(action: ("New Session", terminal.newSession)) {
                    Image(systemName: "checkmark.circle")
                    Text("The shell \(how).")
                }
            case .elsewhere:
                bar(action: ("Show Here", terminal.reconnect)) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text("Open on another device.")
                }
            case .idle:
                bar(action: ("Reconnect", terminal.reconnect)) {
                    Image(systemName: "moon.zzz")
                    Text("Disconnected while idle.")
                }
            case .failed(let message):
                bar(action: ("Try Again", terminal.reconnect)) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).lineLimit(3)
                }
            }
        }
        .animation(.snappy, value: terminal.status)
    }

    private func bar<Content: View>(action: (String, () -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            content()
            if let action {
                Spacer(minLength: 4)
                Button(action.0, action: action.1)
                    .buttonStyle(.glassProminent)
                    .tint(Brand.amber)
                    .foregroundStyle(.black)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .surface(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
