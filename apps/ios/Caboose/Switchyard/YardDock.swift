import CabooseKit
import SwiftUI

/// The Desktop tab's dock: each app appears once, followed by Overview and All Apps.
/// Tapping opens or focuses the app; holding offers its window actions. A swipe up opens
/// Overview. Holding Overview opens Quick Switch: slide to a window and release to select.
struct YardDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.portraitDesktopChrome) private var portraitDesktop
    let yard: YardModel
    let width: CGFloat

    static let height: CGFloat = 58
    private let icon: CGFloat = 38

    var body: some View {
        let columns = yard.layout.columns
        let apps = model.dockApps
        // Keep app icons full-sized; overflow scrolls without duplicating running apps.
        let fixed: CGFloat = 2 * 34 + 1 + 3 * 10 + 24 + (portraitDesktop ? 54 : 0)
        let appWidth = min(max(0, CGFloat(apps.count) * (icon + 10) - 10), max(icon, width - 32 - fixed))
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(apps) { app in
                        // A tap goes to the app; holding it offers Open, Pin and Close. A menu with a
                        // primary action shows on the hold itself, so neither the dock's swipe nor the
                        // system's bottom edge can take the press from it.
                        Menu { DockAppActions(app: app) } label: {
                            VStack(spacing: 3) {
                                Group {
                                    if let image = model.appIcons[app.id] {
                                        Image(uiImage: image).resizable().scaledToFit()
                                    } else {
                                        Image(systemName: "app.dashed").font(.title2)
                                    }
                                }
                                .frame(width: icon, height: icon)
                                .modifier(DockLaunchFeedback(appID: app.id))
                                Circle()
                                    .fill(.white.opacity(isRunning(app) ? 0.85 : 0))
                                    .frame(width: 4, height: 4)
                            }
                            .contentShape(Rectangle())
                        } primaryAction: {
                            model.openOnDesktop(app)
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .accessibilityLabel(app.name)
                        .accessibilityHint("Hold for Open, Pin and Close.")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(width: appWidth, height: icon + 7)
            Divider().frame(height: 34).overlay(.white.opacity(0.3))
            OverviewControl(yard: yard, enabled: true)
            button("All Apps", "square.grid.3x3.fill") { withAnimation(.smooth(duration: 0.3)) { yard.launcherOpen = true } }
            if portraitDesktop { DesktopPanelButton() }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                guard value.translation.height < -30, abs(value.translation.height) > abs(value.translation.width), !columns.isEmpty else { return }
                // A finger that held Overview and slid up was choosing a window, not asking for Overview.
                let switcher = model.quickSwitch
                guard switcher.mode != .hold, Date().timeIntervalSince(switcher.holdEnded) > 0.4 else { return }
                withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true }
            }
        )
        .animation(.smooth(duration: 0.3), value: columns.map(\.id))
    }

    private func isRunning(_ app: HostClient.App) -> Bool {
        model.appWindows.contains { model.matches($0, app) }
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(title)
    }
}

/// Overview on the dock. A tap opens Overview. Held, it opens Quick Switch with nothing
/// selected: sliding up selects the window level with the finger, and letting go goes to it;
/// letting go off the strip, or the gesture being cancelled, stays. VoiceOver offers Switch
/// Windows, which opens the strip to choose from, with Stay Here.
private struct OverviewControl: View {
    @Environment(AppModel.self) private var model
    let yard: YardModel
    let enabled: Bool
    @GestureState private var held = false

    var body: some View {
        let switcher = model.quickSwitch
        Image(systemName: "rectangle.on.rectangle")
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 34, height: 34)
            .background(.white.opacity(switcher.owner == .yard && switcher.mode == .hold ? 0.22 : 0), in: Circle())
            .contentShape(Rectangle())
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .updating($held) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
                    .onChanged { value in
                        guard case .second(true, let drag) = value else { return }
                        if !(switcher.owner == .yard && switcher.mode == .hold) {
                            switcher.hold(recent: recent, desktop: yard.switchTarget())
                        }
                        if let drag { switcher.track(drag.location) }
                    }
                    .onEnded { _ in switcher.release() }
                    .exclusively(before: TapGesture().onEnded { openOverview() }),
                including: enabled ? .all : .none
            )
            // A hold the system took away (a call, a system gesture) stays where it was.
            .onChange(of: held) { _, held in
                if !held, switcher.owner == .yard, switcher.mode == .hold { switcher.cancel() }
            }
            .accessibilityElement()
            .accessibilityLabel("Window Overview")
            .accessibilityHint("Show open windows. Hold and slide up to switch windows.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openOverview() }
            .accessibilityAction(named: "Switch Windows") {
                switcher.present(recent: recent, desktop: yard.switchTarget())
            }
            .disabled(!enabled)
    }

    private var recent: [Int] { model.recentWindowIDs.filter { yard.layout.contains($0) } }

    private func openOverview() {
        guard enabled else { return }
        withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true }
    }
}

/// The same actions for a held dock icon in tiled and free desktops (`DockMenu`).
struct DockAppActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let app: HostClient.App
    /// After an action, for a menu that does not close itself.
    var done: () -> Void = {}

    var body: some View {
        let windows = model.appWindows.filter { model.matches($0, app) }
        let detached = model.detachedWindowIDs
        let actions = DockMenu.actions(appName: app.name, pinned: model.pinnedApps.contains { $0.id == app.id },
                                       windows: windows.map { DockMenu.Window(id: $0.id, title: $0.title, detached: detached.contains($0.id)) },
                                       windowScenes: model.supportsWindowScenes)
        Button("Add Shortcut to Desktop", systemImage: "plus.square") {
            Task { await model.desktopFiles.addShortcut(app, model: model) }; done()
        }
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            switch action {
            case .open:
                Button(action.title, systemImage: "arrow.up.forward.app") { model.openOnDesktop(app); done() }
            case .pin, .unpin:
                Button(action.title, systemImage: action == .pin ? "pin" : "pin.slash") { model.togglePin(app); done() }
            case .openInNewWindow(let id, _):
                Button(action.title, systemImage: "macwindow.badge.plus") {
                    if let window = model.window(id), let ref = model.windowRef(for: window) { openWindow(value: ref) }
                    done()
                }
            case .moveToDesktop(let id, _):
                Button(action.title, systemImage: "rectangle.on.rectangle") { model.moveToDesktop(id); done() }
            case .close(let id, _):
                Button(action.title, systemImage: "xmark", role: .destructive) {
                    if let window = model.session?.windows[id] { model.session?.close(window) }
                    done()
                }
            }
        }
    }
}
