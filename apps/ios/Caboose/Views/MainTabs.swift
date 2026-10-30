import CabooseKit
import SwiftUI

/// The app's shell: Home, the Desktop, Agents and Apps, in the system's tab view. Where the
/// device has a vertical bar (iPhone Duo), the system draws the tab bar and each tab's
/// toolbar together on the side. On an iPhone whose bars are horizontal, the tabs sit at the
/// bottom right instead of across the bottom (`ShellTabChrome`); on iPad they are the
/// system's. Portrait Desktop overrides either placement with its compact panel.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.toolbarVerticalEdgeIfAvailable) private var barEdge
    @Environment(\.scenePhase) private var scenePhase
    @State private var width: CGFloat = 0
    @State private var windowSize: CGSize = .zero
    @State private var windowBottomInset: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        let systemPlacement = HomeToday.tabPlacement(isPhone: UIDevice.current.userInterfaceIdiom == .phone,
                                               hasVerticalBar: barEdge != nil, width: width)
        let portraitDesktop = DesktopChrome.usesCompactPanel(size: windowSize)
        let placement: HomeToday.TabPlacement = portraitDesktop && windowSize.width >= 600 ? .sidebar : systemPlacement
        let desktopHidesBars = (model.selectedTab == .desktop && portraitDesktop) ||
            DesktopChrome.hidesShell(tab: model.selectedTab, laptopDesktop: model.laptopDesktopActive,
                                     laptopTerminal: model.terminalLaptopActive)
        TabView(selection: $model.selectedTab) {
            Tab("Home", systemImage: "house", value: ShellTab.home) {
                HomeScreen().modifier(ShellTabChrome(placement: placement, tab: .home))
            }
            Tab("Desktop", systemImage: "macwindow.on.rectangle", value: ShellTab.desktop) {
                DesktopScreen().modifier(ShellTabChrome(placement: placement, tab: .desktop))
            }
            Tab("Agents", systemImage: "sparkles", value: ShellTab.agents) {
                AgentsScreen().modifier(ShellTabChrome(placement: placement, tab: .agents))
            }
            .badge(model.agents.awaitingApproval.count)
            Tab("Apps", systemImage: "square.grid.2x2", value: ShellTab.apps) {
                AppsScreen().modifier(ShellTabChrome(placement: placement, tab: .apps))
            }
            if TerminalSlot.isFilled {
                Tab("Terminal", systemImage: "apple.terminal", value: ShellTab.terminal) {
                    TerminalSlot.screen().modifier(ShellTabChrome(placement: placement, tab: .terminal))
                }
            }
        }
        .toolbarVisibility(desktopHidesBars || placement != .system ? .hidden : .visible, for: .tabBar)
        .environment(\.shellTabPlacement, placement)
        .environment(\.portraitDesktopChrome, portraitDesktop)
        .environment(\.shellBottomInset, windowBottomInset)
        .environment(\.shellHasVerticalBar, placement == .system && barEdge != nil)
        .background { ShellWindowProbe(sizeChanged: { windowSize = $0 }, bottomInsetChanged: { windowBottomInset = $0 }).allowsHitTesting(false).accessibilityHidden(true) }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .tint(Brand.amber)
        .onChange(of: model.selectedTab) { _, _ in model.updateDeviceDesktop() }
        // Home's strip shows the windows as they were while the computer rests: their
        // pictures are kept as the app leaves the screen, and as the computer parks.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive: HomeFrames.shared.capture(model)
            case .background: UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: SinceYouLeft.leftKey)
            default: break
            }
        }
        .onChange(of: model.parking) { _, parking in
            if parking { HomeFrames.shared.capture(model) }
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.phase == .ready && model.presentedWindowID != nil },
            set: { if !$0 { model.presentedWindowID = nil } }), onDismiss: { model.windowCardDismissed() }) {
            WindowScreen()
                .environment(model)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.presentedAgentWindowID != nil },
            set: { if !$0 { model.presentedAgentWindowID = nil } })) {
            AgentWindowScreen().environment(model)
        }
        .confirmationDialog("Restart your computer?", isPresented: $model.restartConfirmationPresented, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { Task { await model.restartComputer() } }
        } message: {
            Text("Open apps close. Files stay.")
        }
        .alert("Opening App", isPresented: Binding(
            get: { model.launchFailure != nil },
            set: { if !$0 { model.launchFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.launchFailure ?? "")
        }
        .alert("Catalog", isPresented: Binding(get: { model.catalog.error != nil }, set: { if !$0 { model.catalog.error = nil } })) {
            Button("OK", role: .cancel) { model.catalog.error = nil }
        } message: { Text(model.catalog.error ?? "") }
    }
}

/// What a tab that needs the running computer shows until it is: waking, parked, out of
/// reach, or showing on another device.
struct ComputerStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .waking, .connecting, .ready: WakeView(connecting: model.phase != .waking)
            case .restarting: RestartingView()
            case .parked: ParkedView()
            case .failed(let message): FailureView(message: message)
            case .displayElsewhere: ElsewhereView()
            case .needsSetup: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            if model.credentials != nil {
                ComputerSwitcher {
                    Label("Switch Computer", systemImage: "desktopcomputer")
                }
                .buttonStyle(.glass)
                .padding(20)
            }
        }
    }
}

/// Every tab offers saved computers, settings and the lifecycle menu.
/// They overflow last when the vertical bar runs short of room.
struct ComputerToolbar: ToolbarContent {
    var body: some ToolbarContent {
        if #available(iOS 27.0, *) {
            items.visibilityPriority(.high)
        } else {
            items
        }
    }

    private var items: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            ComputerSwitcher { Image(systemName: "desktopcomputer") }
            ComputerSettingsButton()
            LifecycleMenu()
        }
    }
}

private struct ComputerSettingsButton: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Button("Computer", systemImage: "gearshape") { model.settingsPresented = true }
    }
}

/// The computer's state as one control, offering what fits it: Turn On (`POST /v1/session`)
/// when it is parked or out of reach, Park (`POST /v1/session/park`) and Restart
/// (`POST /v1/computer/restart`, where the host can, after confirmation) while it runs.
/// The host has no power-off: Park is the computer at rest.
struct LifecycleMenu: View {
    @Environment(AppModel.self) private var model
    @State private var showingActions = false

    var body: some View {
        Button { showingActions = true } label: {
            Label {
                Text(state.title)
            } icon: {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
                    .symbolEffect(.pulse, isActive: state.busy)
            }
        }
        .accessibilityLabel("Computer: \(state.title)")
        .popover(isPresented: $showingActions, attachmentAnchor: .rect(.bounds)) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Computer").font(.headline)
                ComputerLifecycleActions(statusTitle: state.title) { showingActions = false }
            }
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
            .padding(20)
            .frame(minWidth: 220, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
        .onDisappear { showingActions = false }

    }

    private var state: (title: String, symbol: String, color: Color, busy: Bool) {
        if model.parking { return ("Parking", "moon.zzz", Brand.amber, true) }
        switch model.phase {
        case .ready: return ("Running", "power", .green, false)
        case .waking: return ("Waking", "power", Brand.amber, true)
        case .connecting: return ("Connecting", "power", Brand.amber, true)
        case .restarting: return ("Restarting", "arrow.clockwise", Brand.amber, true)
        case .parked: return ("Parked", "moon.zzz", .secondary, false)
        case .failed: return ("Out of Reach", "exclamationmark.triangle", .orange, false)
        case .displayElsewhere: return ("On Another Device", "rectangle.on.rectangle", .secondary, false)
        case .needsSetup: return ("Not Set Up", "power", .secondary, false)
        }
    }
}

extension View {
    /// Keeps the tab bar whole in the vertical bar (iOS 27.1) and lets the toolbar's own items
    /// overflow first, as on every tab; a no-op where there is no vertical bar.
    @ViewBuilder
    func keepsTabBarInVerticalBar() -> some View {
        if #available(iOS 27.1, *) {
            toolbarVerticalCompressionBehavior(.prefersTabBar)
        } else {
            self
        }
    }
}

/// Shared lifecycle actions for native power popovers and compact rail overflow.
struct ComputerLifecycleActions: View {
    @Environment(AppModel.self) private var model
    var statusTitle = "Computer busy"
    var selected: () -> Void = {}
    var body: some View {
        Group {
                if let upgrade = model.computerStatus?.upgrade, let title = HostMessage.upgradeStatus(upgrade.state) {
                    Button(title, systemImage: upgrade.state == "failed" ? "exclamationmark.triangle" : "arrow.down.circle") {
                        selected()
                        model.settingsPresented = true
                    }
                }
                switch model.phase {
                case .ready:
                    Button("Park", systemImage: "moon.zzz") {
                        selected()
                        Task { try? await model.parkComputer() }
                    }.disabled(model.parking)
                    if model.computerStatus?.capabilities.restart == true {
                        Button("Restart…", systemImage: "arrow.clockwise", role: .destructive) {
                            selected()
                            model.restartConfirmationPresented = true
                        }
                    }
                case .parked, .failed:
                    Button("Turn On", systemImage: "power") {
                        selected()
                        Task { await model.wake() }
                    }
                case .displayElsewhere:
                    Button("Show Here", systemImage: "iphone") {
                        selected()
                        Task { await model.wake() }
                    }
                    Button("Park", systemImage: "moon.zzz") {
                        selected()
                        Task { try? await model.parkComputer() }
                    }
                case .waking, .connecting, .restarting, .needsSetup:
                    Text(statusTitle).foregroundStyle(.secondary)
                }
        }
    }
}
