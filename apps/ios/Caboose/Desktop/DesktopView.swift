import CabooseKit
import SwiftUI

/// The Mac-like desktop shown on an external display: floating Linux windows with native
/// title bars, a dock of the computer's apps, and the cursor the phone's trackpad drives.
struct DesktopView: View {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                WallpaperView(store: WallpaperStore.shared)
                if let session = model.session {
                    ForEach(desktop.stacking.compactMap { session.windows[$0] }.filter { desktop.isVisible($0.id) }) { window in
                        DesktopWindow(window: window, desktop: desktop, icon: model.icon(for: window))
                    }
                }
                if desktop.launchpadOpen {
                    Launchpad(desktop: desktop)
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
                if let session = model.session, desktop.fullscreenWindow(in: session.windows) == nil {
                    Dock(desktop: desktop)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 10 * desktop.ui)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if desktop.showsCursor {
                    Cursor(hit: desktop.hovered, ui: desktop.ui)
                        .position(desktop.cursor)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(name: "desktop")
            .onAppear {
                desktop.size = proxy.size
                WallpaperStore.shared.show(pixelSize: CGSize(width: proxy.size.width * desktop.pixelsPerPoint,
                                                             height: proxy.size.height * desktop.pixelsPerPoint))
            }
            .onDisappear { WallpaperStore.shared.stop() }
            .onChange(of: proxy.size) { _, size in desktop.size = size }
        }
        .ignoresSafeArea()
    }
}

/// One Linux window with a macOS-style title bar.
struct DesktopWindow: View {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let desktop: DesktopModel
    let icon: UIImage?

    var body: some View {
        let chrome = desktop.chromeRect(window)
        VStack(spacing: 0) {
            if !window.isAuxiliary && !window.isFullscreen {
                let ui = desktop.ui
                HStack(spacing: 8 * ui) {
                    TrafficLight(color: .red, symbol: "xmark", hot: desktop.hovered == .close(window.id), ui: ui)
                    TrafficLight(color: .yellow, symbol: "minus", hot: desktop.hovered == .minimize(window.id), ui: ui)
                    TrafficLight(color: .green, symbol: "arrow.up.left.and.arrow.down.right", hot: desktop.hovered == .zoom(window.id), ui: ui)
                    Spacer(minLength: 8 * ui)
                    if let icon { Image(uiImage: icon).resizable().frame(width: 15 * ui, height: 15 * ui) }
                    Text(window.title.isEmpty ? "Window" : window.title)
                        .font(.system(size: 13 * ui, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 60 * ui)
                }
                .padding(.horizontal, 12 * ui)
                .frame(height: desktop.titleBarHeight)
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
            withAnimation(.snappy) { desktop.applyFullscreen(window, session: model.session) }
        }
        .onAppear { if window.isFullscreen { desktop.applyFullscreen(window, session: model.session) } }
    }
}

struct TrafficLight: View {
    let color: Color
    let symbol: String
    let hot: Bool
    var ui: CGFloat = 1

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 12 * ui, height: 12 * ui)
            .overlay {
                if hot { Image(systemName: symbol).font(.system(size: 7 * ui, weight: .black)).foregroundStyle(.black.opacity(0.6)) }
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
    let desktop: DesktopModel

    var body: some View {
        let ui = desktop.ui
        HStack(spacing: 10 * ui) {
            // As many as fit: a phone held upright has room for fewer than a TV.
            let fit = max(3, Int((desktop.size.width - 120 * ui) / (62 * ui)))
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
                    .scaleEffect(hot ? 1.28 : 1, anchor: .bottom)
                    .animation(.spring(duration: 0.22), value: hot)
                    Circle()
                        .fill(.white.opacity(isRunning(app) ? 0.85 : 0))
                        .frame(width: 4 * ui, height: 4 * ui)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop.dockFrames[app.id] = $0 }
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
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop.launchpadButtonFrame = $0 }
        }
        .padding(.horizontal, 12 * ui)
        .padding(.vertical, 8 * ui)
        .glassEffect(.regular, in: .rect(cornerRadius: 22 * ui))
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

/// Every app on the computer, in a grid over the desktop, as on a Mac.
struct Launchpad: View {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel

    var body: some View {
        let ui = desktop.ui
        let apps = model.partitionedApps.main
        let columns = Array(repeating: GridItem(.fixed(150 * ui), spacing: 28 * ui), count: 7)
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            LazyVGrid(columns: columns, spacing: 30 * ui) {
                ForEach(apps.prefix(42)) { app in
                    let hot = desktop.hovered == .launcher(app.id)
                    VStack(spacing: 8 * ui) {
                        Group {
                            if let icon = model.appIcons[app.id] {
                                Image(uiImage: icon).resizable().scaledToFit()
                            } else {
                                Image(systemName: "app.dashed").font(.system(size: 50 * ui))
                            }
                        }
                        .frame(width: 84 * ui, height: 84 * ui)
                        .scaleEffect(hot ? 1.12 : 1)
                        .animation(.spring(duration: 0.2), value: hot)
                        Text(app.name)
                            .font(.system(size: 14 * ui, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                    .frame(width: 150 * ui)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop.launcherFrames[app.id] = $0 }
                }
            }
            .padding(.top, 60 * ui)
            .padding(.bottom, desktop.dockHeight + 40 * ui)
        }
        .onDisappear { desktop.launcherFrames = [:] }
    }
}
