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
                Backdrop()
                if let session = model.session {
                    ForEach(desktop.stacking.compactMap { session.windows[$0] }.filter { desktop.isVisible($0.id) }) { window in
                        DesktopWindow(window: window, desktop: desktop, icon: model.icon(for: window))
                    }
                }
                Dock(desktop: desktop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 10)
                Cursor(hit: desktop.hovered)
                    .position(desktop.cursor)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "desktop")
            .onAppear { desktop.size = proxy.size }
            .onChange(of: proxy.size) { _, size in desktop.size = size }
        }
        .ignoresSafeArea()
    }
}

/// One Linux window with a macOS-style title bar.
struct DesktopWindow: View {
    let window: RemoteWindow
    let desktop: DesktopModel
    let icon: UIImage?

    var body: some View {
        let chrome = desktop.chromeRect(window)
        VStack(spacing: 0) {
            if !window.isAuxiliary {
                HStack(spacing: 8) {
                    TrafficLight(color: .red, symbol: "xmark", hot: desktop.hovered == .close(window.id))
                    TrafficLight(color: .yellow, symbol: "minus", hot: desktop.hovered == .minimize(window.id))
                    TrafficLight(color: .green, symbol: "plus", hot: false)
                    Spacer(minLength: 8)
                    if let icon { Image(uiImage: icon).resizable().frame(width: 15, height: 15) }
                    Text(window.title.isEmpty ? "Window" : window.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 60)
                }
                .padding(.horizontal, 12)
                .frame(height: DesktopModel.titleBarHeight)
                .background(.regularMaterial)
            }
            RemoteWindowSurface(window: window, pixelsPerPoint: desktop.pixelsPerPoint)
        }
        .frame(width: chrome.width, height: chrome.height)
        .clipShape(RoundedRectangle(cornerRadius: window.isAuxiliary ? 6 : 11, style: .continuous))
        .shadow(color: .black.opacity(window.isAuxiliary ? 0.25 : 0.45), radius: window.isAuxiliary ? 8 : 24, y: window.isAuxiliary ? 3 : 12)
        .position(x: chrome.midX, y: chrome.midY)
    }
}

struct TrafficLight: View {
    let color: Color
    let symbol: String
    let hot: Bool

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 12, height: 12)
            .overlay {
                if hot { Image(systemName: symbol).font(.system(size: 7, weight: .black)).foregroundStyle(.black.opacity(0.6)) }
            }
    }
}

/// A display-only window surface; the desktop routes all input itself.
struct RemoteWindowSurface: UIViewRepresentable {
    let window: RemoteWindow
    let pixelsPerPoint: CGFloat

    func makeUIView(context: Context) -> RemoteWindowView {
        let view = RemoteWindowView(session: nil, window: window)
        view.isInteractive = false
        view.pixelsPerPoint = pixelsPerPoint
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        if view.remoteWindow?.id != window.id { view.attach(window) }
    }
}

struct Dock: View {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(model.apps.prefix(14)) { app in
                let hot = desktop.hovered == .dock(app.id)
                VStack(spacing: 3) {
                    Group {
                        if let icon = model.appIcons[app.id] {
                            Image(uiImage: icon).resizable().scaledToFit()
                        } else {
                            Image(systemName: "app.dashed").font(.largeTitle)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .scaleEffect(hot ? 1.28 : 1, anchor: .bottom)
                    .animation(.spring(duration: 0.22), value: hot)
                    Circle()
                        .fill(.white.opacity(isRunning(app) ? 0.85 : 0))
                        .frame(width: 4, height: 4)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("desktop")) } action: { desktop.dockFrames[app.id] = $0 }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func isRunning(_ app: HostClient.App) -> Bool {
        model.appWindows.contains { model.matches($0, app) }
    }
}

struct Cursor: View {
    let hit: DesktopModel.Hit

    var body: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 24, weight: .regular))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 1.5)
            .offset(x: 7, y: 10)
    }
}
