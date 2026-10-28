import CabooseKit
import SwiftUI

/// The app's shell: Home, the Desktop, Agents and Apps, in the system's tab view. Where the
/// device has a vertical bar (iPhone Duo), the system draws the tab bar and each tab's
/// toolbar together on the side; elsewhere they are the usual bars.
struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Home", systemImage: "house", value: ShellTab.home) {
                HomeScreen()
            }
            Tab("Desktop", systemImage: "macwindow.on.rectangle", value: ShellTab.desktop) {
                DesktopScreen()
            }
            Tab("Agents", systemImage: "sparkles", value: ShellTab.agents) {
                AgentsScreen()
            }
            .badge(model.agents.awaitingApproval.count)
            Tab("Apps", systemImage: "square.grid.2x2", value: ShellTab.apps) {
                AppsScreen()
            }
            if TerminalSlot.isFilled {
                Tab("Terminal", systemImage: "apple.terminal", value: ShellTab.terminal) {
                    TerminalSlot.screen()
                }
            }
        }
        .tint(Brand.amber)
        .onChange(of: model.selectedTab) { _, _ in model.updateDeviceDesktop() }
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
        .alert("Couldn't Open", isPresented: Binding(
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
    }
}

/// Every tab's trailing pair: the Computer settings, and the lifecycle menu below it.
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

    var body: some View {
        Menu {
            if let upgrade = model.computerStatus?.upgrade, let title = HostMessage.upgradeStatus(upgrade.state) {
                // The detail is in Computer settings, held to a few lines there.
                Button(title, systemImage: upgrade.state == "failed" ? "exclamationmark.triangle" : "arrow.down.circle") {
                    model.settingsPresented = true
                }
            }
            Section(state.title) {
                switch model.phase {
                case .ready:
                    Button("Park", systemImage: "moon.zzz") { Task { try? await model.parkComputer() } }
                        .disabled(model.parking)
                    if model.computerStatus?.capabilities.restart == true {
                        Button("Restart…", systemImage: "arrow.clockwise", role: .destructive) { model.restartConfirmationPresented = true }
                    }
                case .parked, .failed:
                    Button("Turn On", systemImage: "power") { Task { await model.wake() } }
                case .displayElsewhere:
                    Button("Show Here", systemImage: "iphone") { Task { await model.wake() } }
                    Button("Park", systemImage: "moon.zzz") { Task { try? await model.parkComputer() } }
                case .waking, .connecting, .restarting, .needsSetup:
                    EmptyView()
                }
            }
        } label: {
            Label {
                Text(state.title)
            } icon: {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
                    .symbolEffect(.pulse, isActive: state.busy)
            }
        }
        .accessibilityLabel("Computer: \(state.title)")
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
