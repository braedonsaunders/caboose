import CabooseKit
import SwiftUI

/// One Linux app, full screen, sized to the phone: the window is configured to exactly
/// the space it is shown in, so the app lays itself out for this screen.
struct WindowScreen: View {
    @Environment(AppModel.self) private var model
    @State private var chromeVisible = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let window = model.window(model.presentedWindowID) {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        RemoteWindowCanvas(window: window, keyboardVisible: model.keyboardVisible)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        ForEach(model.auxiliaryWindows(for: window)) { popup in
                            RemoteWindowCanvas(window: popup, keyboardVisible: false)
                                .frame(width: popup.frame.width / model.pixelsPerPoint,
                                       height: popup.frame.height / model.pixelsPerPoint)
                                .offset(popupOffset(popup, in: window, size: proxy.size))
                                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                        }
                    }
                    .onAppear { fit(window, to: proxy.size) }
                    .onChange(of: proxy.size) { _, size in fit(window, to: size) }
                    .onChange(of: window.id) { _, _ in fit(window, to: proxy.size) }
                }
                .padding(.top, chromeVisible ? 52 : 0)
                .ignoresSafeArea(.container, edges: .bottom)
                if chromeVisible { chrome(for: window) }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
    }

    private func chrome(for window: RemoteWindow) -> some View {
        HStack(spacing: 10) {
            Button { model.presentedWindowID = nil } label: {
                Image(systemName: "square.grid.2x2").frame(width: 40, height: 40)
            }
            .glassEffect(.regular.interactive(), in: .circle)

            Menu {
                ForEach(model.appWindows) { other in
                    Button { model.presentedWindowID = other.id } label: {
                        Label(other.title.isEmpty ? "Window" : other.title,
                              systemImage: other.id == window.id ? "checkmark" : "macwindow")
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    if let icon = model.icon(for: window) { Image(uiImage: icon).resizable().frame(width: 20, height: 20) }
                    Text(window.title.isEmpty ? "Window" : window.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
            }
            .glassEffect(.regular.interactive(), in: .capsule)

            Spacer(minLength: 0)

            Button { model.keyboardVisible.toggle() } label: {
                Image(systemName: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard").frame(width: 40, height: 40)
            }
            .glassEffect(.regular.interactive(), in: .circle)

            Menu {
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { chromeVisible = false }
                Button("Redraw", systemImage: "arrow.clockwise") { model.session?.refresh(window) }
                Button("Close Window", systemImage: "xmark", role: .destructive) { model.session?.close(window) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 40, height: 40)
            }
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .foregroundStyle(.white)
    }

    /// Fill the shown area with the window, in Linux pixels.
    private func fit(_ window: RemoteWindow, to size: CGSize) {
        guard size.width > 0, size.height > 0, let session = model.session else { return }
        let target = CGRect(x: 0, y: 0, width: size.width * model.pixelsPerPoint, height: size.height * model.pixelsPerPoint).integral
        if window.frame != target { session.configure(window, frame: target) }
        session.focus(window)
    }

    /// Popups are placed where the server put them relative to their parent, kept on screen.
    private func popupOffset(_ popup: RemoteWindow, in parent: RemoteWindow, size: CGSize) -> CGSize {
        let scale = model.pixelsPerPoint
        let width = popup.frame.width / scale, height = popup.frame.height / scale
        let x = (popup.frame.minX - parent.frame.minX) / scale
        let y = (popup.frame.minY - parent.frame.minY) / scale
        return CGSize(width: min(max(0, x), max(0, size.width - width)), height: min(max(0, y), max(0, size.height - height)))
    }
}

/// An interactive remote window surface.
struct RemoteWindowCanvas: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let keyboardVisible: Bool

    func makeUIView(context: Context) -> RemoteWindowView {
        let view = RemoteWindowView(session: model.session, window: window)
        view.pixelsPerPoint = model.pixelsPerPoint
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        view.session = model.session
        if view.remoteWindow?.id != window.id { view.attach(window) }
        if keyboardVisible, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !keyboardVisible, view.isFirstResponder, model.presentedWindowID == window.id {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }
}

/// A live preview for Home: same surface, no input.
struct RemoteWindowPreview: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow

    func makeUIView(context: Context) -> RemoteWindowView {
        let view = RemoteWindowView(session: nil, window: window)
        view.isInteractive = false
        view.pixelsPerPoint = max(1, window.frame.width / 150)
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        if view.remoteWindow?.id != window.id { view.attach(window) }
        view.pixelsPerPoint = max(1, window.frame.width / 150)
    }
}
