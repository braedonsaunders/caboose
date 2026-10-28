import CabooseKit
import SwiftUI

/// One Linux app, full screen, sized to the phone: the window is configured to exactly
/// the space it is shown in, so the app lays itself out for this screen.
struct WindowScreen: View {
    @Environment(AppModel.self) private var model
    @State private var chromeVisible = true
    @State private var askingAbout: RemoteWindow?

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let window = model.window(model.presentedWindowID) {
                GeometryReader { proxy in
                    // Keys go to the topmost dialog, if one is up, else to the window.
                    let popups = model.auxiliaryWindows(for: window)
                    let keyTarget = popups.last { !$0.isOverrideRedirect }?.id ?? window.id
                    ZStack(alignment: .topLeading) {
                        RemoteWindowCanvas(window: window, keyboardVisible: model.keyboardVisible && keyTarget == window.id)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .modifier(WindowDrop(window: window, pixelsPerPoint: model.pixelsPerPoint))
                        ForEach(popups) { popup in
                            RemoteWindowCanvas(window: popup, keyboardVisible: model.keyboardVisible && keyTarget == popup.id)
                                .frame(width: popup.frame.width / model.pixelsPerPoint,
                                       height: popup.frame.height / model.pixelsPerPoint)
                                .offset(popupOffset(popup, in: window, size: proxy.size))
                                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                                .onAppear { fitDialog(popup, over: window, in: proxy.size) }
                        }
                    }
                    .onChange(of: window.isFullscreen) { _, fullscreen in
                        withAnimation(.snappy) { chromeVisible = !fullscreen }
                    }
                    .onAppear { fit(window, to: proxy.size) }
                    .onChange(of: proxy.size) { _, size in fit(window, to: size) }
                    .onChange(of: window.id) { _, _ in fit(window, to: proxy.size) }
                }
                .padding(.top, chromeVisible ? 52 : 0)
                .ignoresSafeArea(.container, edges: .bottom)
                if chromeVisible {
                    chrome(for: window)
                } else {
                    exitFullScreenHandle
                }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .top) {
            ApprovalBanner().padding(.top, chromeVisible ? 56 : 8)
        }
        .animation(.snappy, value: model.agents.awaitingApproval.first?.pendingApproval?.id)
        .fullScreenCover(item: Binding(
            get: { model.media.handedOff },
            set: { if $0 == nil, model.media.handedOff != nil { Task { await model.media.finished(at: nil) } } })) { media in
            MediaPlayerScreen(media: media).environment(model)
        }
        .sheet(item: $askingAbout) { window in
            AskAboutWindowSheet(window: window).environment(model)
        }
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
    }

    /// In full screen, a pull-down tab at the top edge brings the controls back.
    private var exitFullScreenHandle: some View {
        Capsule()
            .fill(.white.opacity(0.35))
            .frame(width: 44, height: 5)
            .padding(.top, 6)
            .frame(width: 120, height: 28, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { chromeVisible = true } }
            .gesture(DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height > 12 { withAnimation(.snappy) { chromeVisible = true } }
            })
            .accessibilityLabel("Show window controls")
            .accessibilityAddTraits(.isButton)
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
                Section(model.connectionSummary) {}
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { chromeVisible = false }
                if model.agents.available {
                    Button("Ask Agent About This Window", systemImage: "sparkle") { askingAbout = window }
                }
                if let video = model.media.available, window.appClass?.name.lowercased().contains("chromium") == true {
                    Button("Play on iPhone or Apple TV", systemImage: "play.tv") { Task { await model.media.playHere(video) } }
                }
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
        // A window that went full screen on the TV keeps the TV's size there; on the phone it
        // must leave that full screen, or the server keeps it larger than the screen.
        if window.frame != target {
            session.configure(window, frame: target, state: window.isFullscreen ? ["fullscreen": false] : [:])
        }
        session.focus(window)
    }

    /// A dialog (not a menu or tooltip) is moved, and shrunk if it must be, to sit centred in
    /// the shown area: apps size and place dialogs for a desktop, and half of one off the
    /// edge of a phone cannot be reached. The server is told, so clicks land where it shows.
    private func fitDialog(_ dialog: RemoteWindow, over parent: RemoteWindow, in size: CGSize) {
        guard !dialog.isOverrideRedirect, let session = model.session, size.width > 0 else { return }
        let scale = model.pixelsPerPoint
        let margin = 12 * scale
        let area = CGSize(width: size.width * scale, height: size.height * scale)
        let width = min(dialog.frame.width, area.width - 2 * margin)
        let height = min(dialog.frame.height, area.height - 2 * margin)
        let target = CGRect(x: parent.frame.minX + (area.width - width) / 2,
                            y: parent.frame.minY + (area.height - height) / 2,
                            width: width, height: height).integral
        if dialog.frame != target { session.configure(dialog, frame: target) }
        session.focus(dialog)
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
        let model = model
        view.onKeyboardWanted = { wanted in
            if model.keyboardVisible != wanted { model.keyboardVisible = wanted }
        }
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        view.session = model.session
        if view.remoteWindow?.id != window.id { view.attach(window) }
        if keyboardVisible, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !keyboardVisible, view.isFirstResponder {
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
        view.pacer = model.session // a live preview is paced like any window on screen
        view.showsVideo = false // the window's own screen plays its videos
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        view.pacer = model.session
        if view.remoteWindow?.id != window.id { view.attach(window) }
        view.pixelsPerPoint = max(1, window.frame.width / 150)
    }
}
