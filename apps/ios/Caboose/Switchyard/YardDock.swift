import CabooseKit
import SwiftUI

/// The Desktop tab's dock: each app appears once, followed by All Apps.
/// Tapping opens or focuses the app; holding offers its window actions. A swipe up opens
/// Overview.
struct YardDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.portraitDesktopChrome) private var portraitDesktop
    @Environment(\.openWindow) private var openWindow
    let yard: YardModel
    let width: CGFloat

    static let height: CGFloat = 58
    private let icon: CGFloat = 38

    var body: some View {
        let columns = yard.layout.columns
        let apps = model.dockApps
        // Keep app icons full-sized; overflow scrolls without duplicating running apps.
        let fixed: CGFloat = 34 + 1 + 2 * 10 + 24 + (portraitDesktop ? 54 : 0)
        let appWidth = min(max(0, CGFloat(apps.count) * (icon + 10) - 10), max(icon, width - 32 - fixed))
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(apps) { app in
                        // A tap goes to the app; holding it opens its menu above it, in the yard.
                        VStack(spacing: 3) {
                            Group {
                                if let image = model.dockIcon(app) {
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
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SwitchyardView.space)) } action: {
                            yard.dockFrames[app.id] = $0
                        }
                        .onTapGesture { model.openOnDesktop(app) }
                        .onLongPressGesture(minimumDuration: 0.4) { showMenu(app) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(app.name)
                        .accessibilityHint("Hold for Open, Pin and Close.")
                        .accessibilityAction { model.openOnDesktop(app) }
                        .accessibilityAction(named: "Actions") { showMenu(app) }
                    }
                }
                // Extend only the vertical viewport. Horizontal scroll clipping still
                // keeps offscreen apps out of the fixed dock controls.
                .padding(.top, DockLaunchFeedback.maximumLift)
            }
            .scrollIndicators(.hidden)
            .frame(width: appWidth, height: icon + 7 + DockLaunchFeedback.maximumLift)
            .padding(.top, -DockLaunchFeedback.maximumLift)
            Divider().frame(height: 34).overlay(.white.opacity(0.3))
            button("All Apps", "square.grid.3x3.fill") { withAnimation(.smooth(duration: 0.3)) { yard.launcherOpen = true } }
            if portraitDesktop { DesktopPanelButton() }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background {
            Color.clear.glassEffect(.regular, in: ConcentricRectangle(cornerRadius: 22))
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                guard value.translation.height < -30, abs(value.translation.height) > abs(value.translation.width), !columns.isEmpty else { return }
                withAnimation(.smooth(duration: 0.35)) { yard.overviewOpen = true }
            }
        )
        .animation(.smooth(duration: 0.3), value: columns.map(\.id))
    }

    /// The app's actions, above its icon.
    private func showMenu(_ app: HostClient.App) {
        guard let frame = yard.dockFrames[app.id] else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        yard.menu.show(DockAppActions.items(app, model: model, openWindow: openWindow),
                       at: CGPoint(x: frame.minX, y: frame.minY - 6), above: true)
    }

    private func isRunning(_ app: HostClient.App) -> Bool { model.isRunning(app) }

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

/// The same actions for a held dock icon in tiled and free desktops (`DockMenu`).
struct DockAppActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let app: HostClient.App
    /// After an action, for a menu that does not close itself.
    var done: () -> Void = {}

    var body: some View {
        ForEach(Array(Self.items(app, model: model, openWindow: openWindow).enumerated()), id: \.offset) { _, item in
            Button(item.title, systemImage: item.systemImage, role: item.destructive ? .destructive : nil) {
                item.perform(); done()
            }
        }
    }

    /// The rows, for this menu and for the desktop's pointer menu.
    static func items(_ app: HostClient.App, model: AppModel, openWindow: OpenWindowAction) -> [DesktopModel.MenuItem] {
        let windows = model.appWindows.filter { model.matches($0, app) }
        let detached = model.detachedWindowIDs
        let unlisted = model.isUnlisted(app)
        let actions = DockMenu.actions(appName: app.name, pinned: model.pinnedApps.contains { $0.id == app.id }, pinnable: !unlisted,
                                       windows: windows.map { DockMenu.Window(id: $0.id, title: $0.title, detached: detached.contains($0.id)) },
                                       windowScenes: model.supportsWindowScenes, ending: ending(app, windows: windows, model: model))
        let windowIDs = windows.map(\.id)
        // An application no desktop entry claims has no entry to put on the desktop.
        var items = unlisted ? [] : [DesktopModel.MenuItem(title: "Add Shortcut to Desktop", systemImage: "plus.square") {
            Task { await model.desktopFiles.addShortcut(app, model: model) }
        }]
        for action in actions {
            switch action {
            case .open:
                items.append(.init(title: action.title, systemImage: "arrow.up.forward.app") { model.openOnDesktop(app) })
            case .pin, .unpin:
                items.append(.init(title: action.title, systemImage: action == .pin ? "pin" : "pin.slash") { model.togglePin(app) })
            case .openInNewWindow(let id, _):
                items.append(.init(title: action.title, systemImage: "macwindow.badge.plus") {
                    if let window = model.window(id), let ref = model.windowRef(for: window) { openWindow(value: ref) }
                })
            case .moveToDesktop(let id, _):
                items.append(.init(title: action.title, systemImage: "rectangle.on.rectangle") { model.moveToDesktop(id) })
            case .close(let id, _):
                items.append(.init(title: action.title, systemImage: "xmark", destructive: true) {
                    if let window = model.session?.windows[id] { model.session?.closeDiagnosed(window) }
                })
            case .quit:
                items.append(.init(title: action.title, systemImage: "xmark.circle") {
                    Task { await model.runningApps.quitEntry(name: app.name, windowIDs: windowIDs, desktopID: app.id, model: model) }
                })
            case .forceQuit:
                items.append(.init(title: action.title, systemImage: "xmark.octagon", destructive: true) {
                    Task { await model.runningApps.confirmForceQuitEntry(name: app.name, windowIDs: windowIDs, desktopID: app.id, model: model) }
                })
            }
        }
        if model.runningAppsAvailable {
            items.append(.init(title: "Task Manager", systemImage: "gauge.with.dots.needle.33percent") { model.taskManagerPresented = true })
        }
        return items
    }

    /// Quit and Force Quit where the computer has app scopes: from its windows here, and the
    /// last listing for an app that runs without one. The action reads a fresh listing.
    private static func ending(_ app: HostClient.App, windows: [RemoteWindow], model: AppModel) -> DockMenu.Ending? {
        guard model.runningAppsAvailable else { return nil }
        if !windows.isEmpty { return DockMenu.Ending(canQuit: true, canForceQuit: true) }
        return DockMenu.Ending(model.dockRunningApps(app))
    }
}
