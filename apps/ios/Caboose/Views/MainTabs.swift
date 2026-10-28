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
        }
        .tint(Brand.amber)
        .onChange(of: model.selectedTab) { _, _ in model.updateDeviceDesktop() }
        .fullScreenCover(isPresented: Binding(
            get: { model.phase == .ready && model.presentedWindowID != nil && !model.desktopActive },
            set: { if !$0 { model.presentedWindowID = nil } })) {
            WindowScreen()
                .environment(model)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.presentedAgentWindowID != nil },
            set: { if !$0 { model.presentedAgentWindowID = nil } })) {
            AgentWindowScreen().environment(model)
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

extension View {
    /// Prefers keeping a task's toolbar items over the tab bar when the vertical bar is short
    /// of space (iOS 27.1); a no-op where there is no vertical bar.
    @ViewBuilder
    func prefersToolbarItemsInVerticalBar() -> some View {
        if #available(iOS 27.1, *) {
            toolbarVerticalCompressionBehavior(.prefersToolbarItems)
        } else {
            self
        }
    }
}
