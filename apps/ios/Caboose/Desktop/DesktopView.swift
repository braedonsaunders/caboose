import CabooseKit
import SwiftUI

/// The Mac-like desktop shown on an external display: floating Linux windows with native
/// title bars, a dock of the computer's apps, and the cursor the phone's trackpad drives.
struct DesktopView: View {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel
    /// A TV's desktop covers the whole screen; the phone's stays inside the bars.
    var fillsScreen = true
    var showsDock = true

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // On the phone the tab draws the wallpaper, under its bars too.
                if fillsScreen { WallpaperView(store: WallpaperStore.shared) }
                DesktopFilesView(desktop: desktop)
                    .frame(width: proxy.size.width, height: max(0, proxy.size.height - desktop.dockHeight))
                // Where the window being dragged would snap if let go now.
                if let preview = desktop.snapPreview {
                    RoundedRectangle(cornerRadius: 12 * desktop.ui, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .strokeBorder(.white.opacity(0.55), lineWidth: 1.5)
                        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 12 * desktop.ui, style: .continuous))
                        .frame(width: preview.width, height: preview.height)
                        .position(x: preview.midX, y: preview.midY)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if let session = model.session {
                    ForEach(desktop.shownWindows.compactMap { session.windows[$0] }) { window in
                        DesktopWindow(window: window, desktop: desktop, icon: model.icon(for: window))
                    }
                }
                if desktop.launchpadOpen {
                    Launchpad(desktop: desktop)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
                if showsDock, !desktop.detachedChrome, let session = model.session, desktop.fullscreenWindow(in: session.windows) == nil {
                    Dock(desktop: desktop)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, desktop.dockBottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // Its rows are hit-tested by the desktop, in this space, like the dock.
                QuickSwitchStrip(owner: .desktop, height: desktop.workArea.height, space: .named("desktop"), tappable: false)
                    .frame(width: desktop.size.width, height: desktop.workArea.height)
                if desktop.showsCursor && !desktop.detachedChrome {
                    Cursor(hit: desktop.hovered, ui: desktop.ui)
                        .position(desktop.cursor)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "desktop")
            .task(id: ObjectIdentifier(desktop)) { desktop.quickSwitch = model.quickSwitch }
            .onAppear {
                if !model.windowCardOwnsGeometry { desktop.size = proxy.size }
                if fillsScreen {
                    WallpaperStore.shared.show(pixelSize: CGSize(width: proxy.size.width * desktop.pixelsPerPoint,
                                                                 height: proxy.size.height * desktop.pixelsPerPoint))
                }
            }
            .onDisappear { if fillsScreen { WallpaperStore.shared.stop() } }
            .onChange(of: proxy.size) { _, size in
                guard !model.windowCardOwnsGeometry else { return }
                desktop.size = size
                desktop.relayout(session: model.session)
            }
            .onChange(of: desktop.ui) { _, _ in
                if !model.windowCardOwnsGeometry { desktop.relayout(session: model.session) }
            }
        }
        .ignoresSafeArea(edges: fillsScreen ? .all : [])
        .clipped()
    }
}

/// One Linux window with a macOS-style title bar.
struct DesktopWindow: View {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let desktop: DesktopModel
    let icon: UIImage?

    private var hoveredControl: WindowTitleBar.Control? {
        switch desktop.hovered {
        case .close(window.id): .close
        case .minimize(window.id): .minimize
        case .zoom(window.id): .zoom
        default: nil
        }
    }

    var body: some View {
        let chrome = desktop.chromeRect(window)
        VStack(spacing: 0) {
            if !desktop.detachedChrome && !window.isAuxiliary && !window.isFullscreen {
                let ui = desktop.ui
                let bar = desktop.titleBar
                HStack(spacing: 0) {
                    // Under a finger the symbols always show; a pointer shows them on hover.
                    WindowControls(bar: bar, hovered: hoveredControl, showsSymbols: desktop.directTouch && !desktop.pointerHovering)
                    Spacer(minLength: 8 * ui)
                    if let icon { Image(uiImage: icon).resizable().frame(width: 15 * ui, height: 15 * ui).padding(.trailing, 6 * ui) }
                    Text(window.title.isEmpty ? "Window" : window.title)
                        .font(.system(size: 13 * ui, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8 * ui)
                    // Balances the controls, so the title is centred on the window.
                    Color.clear.frame(width: bar.controlsWidth)
                }
                .frame(height: bar.height)
                .background(.regularMaterial)
            }
            RemoteWindowSurface(window: window, pixelsPerPoint: desktop.pixelsPerPoint)
                .modifier(WindowDrop(window: window, pixelsPerPoint: desktop.pixelsPerPoint))
        }
        .frame(width: chrome.width, height: chrome.height)
        .clipShape(RoundedRectangle(cornerRadius: window.isFullscreen ? 0 : (window.isAuxiliary ? 6 : 11) * desktop.ui, style: .continuous))
        .shadow(color: .black.opacity(window.isAuxiliary ? 0.25 : 0.45), radius: window.isAuxiliary ? 8 : 24, y: window.isAuxiliary ? 3 : 12)
        .position(x: chrome.midX, y: chrome.midY)
        .onChange(of: window.isFullscreen) { _, _ in
            if !model.windowCardOwnsGeometry {
                withAnimation(.snappy) { desktop.applyFullscreen(window, session: model.session) }
            }
        }
        .onAppear {
            if window.isFullscreen && !model.windowCardOwnsGeometry { desktop.applyFullscreen(window, session: model.session) }
        }
    }
}

/// A display-only window surface; the desktop routes all input itself.
struct RemoteWindowSurface: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let pixelsPerPoint: CGFloat

    func makeUIView(context: Context) -> RemoteWindowView {
        let view = RemoteWindowView(session: nil, window: window)
        view.isInteractive = false
        view.pixelsPerPoint = pixelsPerPoint
        view.pacer = model.session
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        view.pacer = model.session
        if view.remoteWindow?.id != window.id { view.attach(window) }
    }
}

struct Dock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.portraitDesktopChrome) private var portraitDesktop
    let desktop: DesktopModel
    var compact = false
    var coordinateSpace = "desktop"
    var interactive = false

    var body: some View {
        if compact { laptopTaskbar }
        else { floatingDock }
    }

    @ViewBuilder private var floatingDock: some View {
        let ui = desktop.ui
        HStack(spacing: 10 * ui) {
            // As many as fit: a phone held upright has room for fewer than a TV.
            let fit = max(3, Int((desktop.size.width - (portraitDesktop ? 174 : 120) * ui) / (62 * ui)))
            ForEach(model.dockApps.prefix(fit)) { app in
                let hot = desktop.hovered == .dock(app.id)
                VStack(spacing: 3 * ui) {
                    Group {
                        if let icon = model.appIcons[app.id] {
                            Image(uiImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "app.dashed").font(.largeTitle)
                        }
                    }
                    .frame(width: 52 * ui, height: 52 * ui)
                    .modifier(DockLaunchFeedback(appID: app.id))
                    .scaleEffect(hot ? 1.28 : 1, anchor: .bottom)
                    .animation(.spring(duration: 0.22), value: hot)
                    Circle()
                        .fill(.white.opacity(isRunning(app) ? 0.85 : 0))
                        .frame(width: 4 * ui, height: 4 * ui)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateSpace)) } action: { desktop.dockFrames[app.id] = $0 }
                .onTapGesture { if interactive { model.openOnDesktop(app) } }
                .onLongPressGesture { if interactive { desktop.contextDockID = app.id } }
                .popover(isPresented: Binding(get: { desktop.contextDockID == app.id }, set: { if !$0 { desktop.contextDockID = nil } })) {
                    VStack(alignment: .leading, spacing: 16) { DockAppActions(app: app) { desktop.contextDockID = nil } }
                        .padding(20)
                        .presentationCompactAdaptation(.popover)
                }
            }
            Divider().frame(height: 44 * ui).overlay(.white.opacity(0.25))
            let hot = desktop.hovered == .launchpadButton
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 26 * ui, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 52 * ui, height: 52 * ui)
                .background(.white.opacity(desktop.launchpadOpen ? 0.25 : 0.12), in: RoundedRectangle(cornerRadius: 12 * ui, style: .continuous))
                .scaleEffect(hot ? 1.28 : 1, anchor: .bottom)
                .animation(.spring(duration: 0.22), value: hot)
                .padding(.bottom, 7 * ui)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateSpace)) } action: { desktop.launchpadButtonFrame = $0 }
                .onTapGesture { if interactive { desktop.launchpadOpen.toggle() } }
            if portraitDesktop { DesktopPanelButton() }
        }
        .padding(.horizontal, 12 * ui)
        .padding(.vertical, 8 * ui)
        .glassEffect(.regular, in: .rect(cornerRadius: 22 * ui))
    }

    /// A continuous, thin strip below the hinge, never a floating capsule over content.
    private var laptopTaskbar: some View {
        HStack(spacing: 0) {
            let fit = max(1, Int((desktop.size.width - 60) / 44))
            ForEach(model.dockApps.prefix(fit)) { app in
                ZStack(alignment: .bottom) {
                    Group {
                        if let icon = model.appIcons[app.id] {
                            Image(uiImage: icon).resizable().scaledToFit()
                        } else { Image(systemName: "app.dashed").font(.title3) }
                    }
                    .frame(width: 26, height: 26)
                    .modifier(DockLaunchFeedback(appID: app.id))
                    .frame(width: 44, height: 44)
                    if isRunning(app) {
                        Capsule().fill(.primary.opacity(0.75)).frame(width: 12, height: 2).padding(.bottom, 3)
                    }
                }
                .background(desktop.hovered == .dock(app.id) ? Color.primary.opacity(0.12) : .clear)
                .contentShape(Rectangle())
                .accessibilityLabel(app.name)
                .accessibilityAddTraits(.isButton)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateSpace)) } action: { desktop.dockFrames[app.id] = $0 }
                .onTapGesture { model.openOnDesktop(app) }
                .onLongPressGesture { desktop.contextDockID = app.id }
                .popover(isPresented: Binding(get: { desktop.contextDockID == app.id }, set: { if !$0 { desktop.contextDockID = nil } })) {
                    VStack(alignment: .leading, spacing: 16) { DockAppActions(app: app) { desktop.contextDockID = nil } }
                        .padding(20).presentationCompactAdaptation(.popover)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .background(desktop.launchpadOpen || desktop.hovered == .launchpadButton ? Color.primary.opacity(0.12) : .clear)
                .contentShape(Rectangle())
                .accessibilityLabel("All Apps")
                .accessibilityAddTraits(.isButton)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(coordinateSpace)) } action: { desktop.launchpadButtonFrame = $0 }
                .onTapGesture { desktop.launchpadOpen.toggle() }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.12)).frame(height: 0.5) }
        .onDisappear { desktop.dockFrames.removeAll(); desktop.launchpadButtonFrame = .zero }
    }

    private func isRunning(_ app: HostClient.App) -> Bool {
        model.appWindows.contains { model.matches($0, app) }
    }
}

struct Cursor: View {
    let hit: DesktopModel.Hit
    var ui: CGFloat = 1

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 24 * ui, weight: .regular))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 1.5 * ui)
            // The symbol's tip is 3.5 × 2.5 points into its 20 × 28 glyph; this puts the tip,
            // not the glyph's centre, on the point that clicks land on.
            .offset(x: 6.5 * ui, y: 11.5 * ui)
    }
}

/// Every app on the computer, in a grid over the desktop, as on a Mac. The grid fits the
/// desktop it is on: up to seven columns on a big screen, fewer beside a phone's bars, and as
/// many rows as fit above the dock.
struct Launchpad: View {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel

    var body: some View {
        let ui = desktop.ui
        let apps = model.partitionedApps.main
        let layout = LaunchpadLayout(size: desktop.size, ui: ui, dockHeight: desktop.dockHeight)
        let range = layout.pageRange(desktop.launcherPage, count: apps.count)
        let columns = Array(repeating: GridItem(.fixed(layout.column), spacing: layout.spacing), count: layout.columns)
        ZStack(alignment: .top) {
            Rectangle().fill(.ultraThinMaterial)
            LazyVGrid(columns: columns, spacing: layout.spacing) {
                ForEach(Array(apps[range])) { app in
                    let hot = desktop.hovered == .launcher(app.id)
                    VStack(spacing: 8 * ui) {
                        Group {
                            if let icon = model.appIcons[app.id] {
                                Image(uiImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: layout.icon * 0.6))
                            }
                        }
                        .frame(width: layout.icon, height: layout.icon)
                        .scaleEffect(hot ? 1.12 : 1)
                        .animation(.spring(duration: 0.2), value: hot)
                        Text(app.name)
                            .font(.system(size: 14 * ui, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                    .frame(width: layout.column)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop.launcherFrames[app.id] = $0 }
                }
            }
            .padding(.top, layout.top)
            .id("\(desktop.launcherPage)-\(apps.map(\.id).joined(separator: ","))-\(desktop.size.width)-\(desktop.size.height)")
            if apps.count > layout.columns * layout.rows {
                HStack(spacing: 24 * ui) {
                    if range.lowerBound > 0 { pageArrow(-1, symbol: "chevron.left", ui: ui) }
                    Text("\(range.lowerBound / (layout.columns * layout.rows) + 1) / \((apps.count + layout.columns * layout.rows - 1) / (layout.columns * layout.rows))")
                        .foregroundStyle(.white).font(.system(size: 14 * ui, weight: .semibold))
                    if range.upperBound < apps.count { pageArrow(1, symbol: "chevron.right", ui: ui) }
                }
                .id("\(desktop.launcherPage)-\(apps.count)-\(desktop.size.width)-\(desktop.size.height)")
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, desktop.dockHeight + 12 * ui)
            }
        }
        .frame(width: desktop.size.width, height: desktop.size.height)
        .clipped()
        .onChange(of: apps.map(\.id)) { _, _ in resetFrames(layout: layout, count: apps.count) }
        .onChange(of: desktop.size) { _, _ in resetFrames(layout: layout, count: apps.count) }
        .onDisappear { desktop.launcherFrames = [:]; desktop.launcherPageFrames = [:]; desktop.launcherPage = 0 }
    }

    private func resetFrames(layout: LaunchpadLayout, count: Int) {
        desktop.launcherFrames = [:]
        desktop.launcherPageFrames = [:]
        desktop.launcherPage = layout.clampedPage(desktop.launcherPage, count: count)
    }

    private func pageArrow(_ direction: Int, symbol: String, ui: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16 * ui, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44 * ui, height: 44 * ui)
            .background(.white.opacity(0.16), in: Circle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop.launcherPageFrames[direction] = $0 }
    }
}

/// ⌘⌥ (Ctrl+Alt to Linux, the chord Linux desktops keep for the window manager) arranges
/// the floating desktop, as it moves Switchyard: the arrows bring the nearest window that
/// way forward, and with ⇧ snap the front window to a side, maximize it or put it back.
/// Plain ⌘ stays the apps' Ctrl. They show in the ⌘-hold overlay on iPad.
struct DesktopKeyCommands: View {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel

    var body: some View {
        Group {
            key("Focus Left", .leftArrow) { desktop.moveFocus(.left, session: model.session) }
            key("Focus Right", .rightArrow) { desktop.moveFocus(.right, session: model.session) }
            key("Focus Up", .upArrow) { desktop.moveFocus(.up, session: model.session) }
            key("Focus Down", .downArrow) { desktop.moveFocus(.down, session: model.session) }
            key("Snap Left", .leftArrow, shift: true) { snap(.left) }
            key("Snap Right", .rightArrow, shift: true) { snap(.right) }
            key("Maximize", .upArrow, shift: true) { snap(.maximized) }
            key("Restore", .downArrow, shift: true) { snap(nil) }
            key("Zoom", "f") { front { desktop.toggleZoom($0.id, $1) } }
            key("Minimize", "m") { front { window, _ in desktop.minimize(window.id) } }
            key("Close Window", "w") { front { $1.close($0) } }
            key("Launchpad", "a") { withAnimation(.smooth(duration: 0.3)) { desktop.launchpadOpen.toggle() } }
            key("New Terminal", .return) { model.openTerminalApp() }
            QuickSwitchKeys(recent: { model.recentWindowIDs }) { desktop.switchTarget(session: model.session) }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func front(_ action: (RemoteWindow, any DisplaySession) -> Void) {
        guard let session = model.session, let window = desktop.frontWindow(in: session.windows) else { return }
        action(window, session)
    }

    private func snap(_ snap: FreeDesktopLayout.Snap?) {
        front { window, session in desktop.snap(window.id, snap, session) }
    }

    private func key(_ title: String, _ key: KeyEquivalent, shift: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: shift ? [.command, .option, .shift] : [.command, .option])
    }
}
