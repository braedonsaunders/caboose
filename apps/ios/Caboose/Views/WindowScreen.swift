import CabooseKit
import SwiftUI

/// One Linux app, full screen, sized to the phone: the window is configured to exactly
/// the space it is shown in, so the app lays itself out for this screen. A swipe in from
/// either side edge goes to the next or previous open app, in the order they opened.
struct WindowScreen: View {
    @Environment(AppModel.self) private var model
    @State private var chromeVisible = true
    @State private var laptopActive = false
    @State private var verticalEdge: HorizontalEdge?
    @State private var enteredVerticalLayout = false
    @State private var askingAbout: RemoteWindow?
    @State private var showingApps = false
    @State private var showingOptions = false
    /// How far the card has been swiped sideways, and the picture of the app it reveals.
    @State private var swipe: CGFloat = 0
    @State private var neighbour: (id: Int, picture: CGImage?)?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ShellBackground()
                if let window = model.window(model.presentedWindowID) {
                    WindowCardViewport(controlsVisible: chromeVisible && !laptopActive, verticalEdge: $verticalEdge) { _ in
                        LaptopContainer(isCard: true, activeChanged: { active in
                            laptopActive = active
                            // Enter the shared desktop when a card folds into Laptop.
                            // Its lower dock and whole-desktop pointer have one owner.
                            if active, !model.externalDisplayActive, let id = model.presentedWindowID {
                                model.setLaptopDesktop(true)
                                model.show(windowID: id)
                            }
                        }) { _ in
                            GeometryReader { proxy in surface(for: window, size: proxy.size) }
                        }
                    }
                    if !chromeVisible && !laptopActive { exitFullScreenHandle }
                } else {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ConnectionBanner()
            }
            .navigationTitle(model.window(model.presentedWindowID)?.title ?? "Window")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                if !laptopActive, let window = model.window(model.presentedWindowID) { controls(for: window) }
            }
            .toolbarVisibility(chromeVisible && !laptopActive ? .automatic : .hidden, for: .navigationBar)
            .toolbarBackground(toolbarBackground, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .onChange(of: verticalEdge) { _, edge in
                // Hiding the native bar can clear its environment edge. It must not
                // reveal itself again in response to its own visibility change.
                if edge != nil && !enteredVerticalLayout {
                    enteredVerticalLayout = true
                    chromeVisible = false
                }
            }
            .overlay(alignment: .top) { ApprovalBanner().padding(.top, 8) }
            .animation(.snappy, value: model.agents.awaitingApproval.first?.pendingApproval?.id)
            .statusBarHidden(!chromeVisible || laptopActive)
            .persistentSystemOverlays(chromeVisible && !laptopActive ? .automatic : .hidden)
        }
        .tint(Brand.amber)
        .fullScreenCover(item: Binding(
            get: { model.media.handedOff },
            set: { if $0 == nil, model.media.handedOff != nil { Task { await model.media.finished(at: nil) } } })) { media in
            MediaPlayerScreen(media: media).environment(model)
        }
        .sheet(item: $askingAbout) { window in
            AskAboutWindowSheet(window: window).environment(model)
        }
    }

    /// The native bar paints the selected wallpaper itself, rather than sampling the
    /// remote app beneath its material. The fallback uses the shell's dusk colours.
    private var toolbarBackground: AnyShapeStyle {
        if let image = WallpaperStore.shared.image {
            return AnyShapeStyle(ImagePaint(image: Image(uiImage: image)))
        }
        return AnyShapeStyle(LinearGradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.20),
                                                     Color(red: 0.12, green: 0.06, blue: 0.10)],
                                            startPoint: .top, endPoint: .bottom))
    }

    /// Keep the remote surface separate from the shell's toolbar and presentation tree.
    private func surface(for window: RemoteWindow, size: CGSize) -> some View {
        // Keys go to the topmost dialog, if one is up, else to the window.
        let popups = model.auxiliaryWindows(for: window)
        let keyTarget = popups.last { !$0.isOverrideRedirect }?.id ?? window.id
        let frames = popupFrames(popups, over: window, size: size)
        return ZStack(alignment: .topLeading) {
            RemoteWindowCanvas(window: window, keyboardVisible: model.keyboardVisible && keyTarget == window.id)
                .frame(width: size.width, height: size.height)
                .modifier(WindowDrop(window: window, pixelsPerPoint: model.pixelsPerPoint))
            ForEach(popups) { popup in
                if let frame = frames[popup.id] {
                    RemoteWindowCanvas(window: popup, keyboardVisible: model.keyboardVisible && keyTarget == popup.id)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                        .onAppear { fitDialog(popup, over: window, in: size) }
                        .onChange(of: size) { _, size in fitDialog(popup, over: window, in: size) }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .offset(x: swipe)
        .background(alignment: .topLeading) { neighbourCard(width: size.width) }
        .overlay { cardEdges(from: window, width: size.width) }
        .onChange(of: window.isFullscreen) { _, fullscreen in
            withAnimation(.snappy) { chromeVisible = !fullscreen }
        }
        .onAppear { fit(window, to: size) }
        .onChange(of: size) { _, size in fit(window, to: size) }
        .onChange(of: window.id) { _, _ in fit(window, to: size) }
    }

    // MARK: Swiping between apps

    /// The open apps' windows in the order they opened, so swiping is predictable.
    private var cardOrder: [RemoteWindow] { model.appWindows.sorted { $0.id < $1.id } }

    /// The app the card swipes towards: the next one for a swipe to the left.
    private func neighbour(of window: RemoteWindow, leftward: Bool) -> RemoteWindow? {
        let order = cardOrder
        guard let index = order.firstIndex(where: { $0.id == window.id }) else { return nil }
        let target = leftward ? index + 1 : index - 1
        return order.indices.contains(target) ? order[target] : nil
    }

    /// The next app's last picture, sliding in beside the card.
    @ViewBuilder private func neighbourCard(width: CGFloat) -> some View {
        if swipe != 0, let neighbour {
            Group {
                if let picture = neighbour.picture {
                    Image(decorative: picture, scale: model.pixelsPerPoint)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    Color(white: 0.08)
                }
            }
            .clipped()
            .offset(x: swipe + (swipe < 0 ? width + 12 : -width - 12))
        }
    }

    /// Thin strips along the side edges, clear of the app, that swipe the card.
    private func cardEdges(from window: RemoteWindow, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if verticalEdge == .leading {
                Color.clear.frame(width: 24).contentShape(Rectangle()).gesture(sidebarSwipe)
            } else {
                Color.clear.frame(width: 14).contentShape(Rectangle()).gesture(cardSwipe(from: window, width: width))
            }
            Spacer(minLength: 0).allowsHitTesting(false)
            if verticalEdge == .trailing {
                Color.clear.frame(width: 24).contentShape(Rectangle()).gesture(sidebarSwipe)
            } else {
                Color.clear.frame(width: 14).contentShape(Rectangle()).gesture(cardSwipe(from: window, width: width))
            }
        }
    }

    /// The native toolbar is revealed from its edge and dismissed towards that edge.
    private var sidebarSwipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                guard abs(value.translation.width) > 30 else { return }
                withAnimation(.snappy) {
                    chromeVisible = verticalEdge == .leading ? value.translation.width > 0 : value.translation.width < 0
                }
            }
    }

    private func cardSwipe(from window: RemoteWindow, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let leftward = value.translation.width < 0
                let target = neighbour(of: window, leftward: leftward)
                if neighbour?.id != target?.id {
                    neighbour = target.map { ($0.id, $0.surface.snapshot()) }
                }
                // Past the first or last app the card only gives a little.
                swipe = target == nil ? value.translation.width * 0.2 : value.translation.width
            }
            .onEnded { value in
                let projected = value.translation.width + value.velocity.width * 0.15
                guard let target = neighbour, abs(projected) > width * 0.35, (projected < 0) == (value.translation.width < 0) else {
                    withAnimation(.smooth(duration: 0.3, extraBounce: 0.12)) { swipe = 0 }
                    return
                }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                withAnimation(.smooth(duration: 0.28), completionCriteria: .logicallyComplete) {
                    swipe = projected < 0 ? -width - 12 : width + 12
                } completion: {
                    model.presentedWindowID = target.id
                    swipe = 0
                    neighbour = nil
                }
            }
    }

    /// In full screen, a pull-down tab at the top edge brings the controls back.
    private var exitFullScreenHandle: some View {
        Button {
            withAnimation(.snappy) { chromeVisible = true }
        } label: {
            Capsule()
                .fill(.white.opacity(0.35))
                .frame(width: 44, height: 5)
                .padding(.top, 6)
                .frame(width: 120, height: 44, alignment: .top)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gesture(DragGesture(minimumDistance: 8).onEnded { value in
            if value.translation.height > 12 { withAnimation(.snappy) { chromeVisible = true } }
        })
        .accessibilityLabel("Show window controls")
    }

    /// Native icon items join the system's side bar on Duo and fit a horizontal toolbar
    /// elsewhere. The window title stays in the switcher instead of taking a content row.
    @ToolbarContentBuilder private func controls(for window: RemoteWindow) -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { LaptopModeMenu() }
        ToolbarItem(placement: .topBarLeading) {
            Button("Back to \(model.selectedTab.rawValue.capitalized)", systemImage: "chevron.backward") {
                model.presentedWindowID = nil
            }
            .labelStyle(.iconOnly)
            .simultaneousGesture(toolbarDismissSwipe)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if verticalEdge != nil {
                Button("Hide Sidebar", systemImage: verticalEdge == .leading ? "sidebar.left" : "sidebar.right") {
                    withAnimation(.snappy) { chromeVisible = false }
                }
                .labelStyle(.iconOnly)
                .simultaneousGesture(toolbarDismissSwipe)
            }
            Button("Switch App", systemImage: "macwindow.on.rectangle") { showingApps = true }
                .labelStyle(.iconOnly)
                .accessibilityValue(window.title.isEmpty ? "Window" : window.title)
                .simultaneousGesture(toolbarDismissSwipe)
                .confirmationDialog("Switch App", isPresented: $showingApps, titleVisibility: .visible) {
                    ForEach(cardOrder) { other in
                        Button { model.presentedWindowID = other.id } label: {
                            Label(other.title.isEmpty ? "Window" : other.title,
                                  systemImage: other.id == model.presentedWindowID ? "checkmark" : "macwindow")
                        }
                    }
                } message: {
                    Text(window.title.isEmpty ? "Window" : window.title)
                }

            if !model.keyboardVisible {
                Button("Keyboard", systemImage: "keyboard") { model.keyboardVisible = true }
                    .labelStyle(.iconOnly)
                    .simultaneousGesture(toolbarDismissSwipe)
            }

            Button("Window Options", systemImage: "ellipsis") { showingOptions = true }
                .labelStyle(.iconOnly)
                .simultaneousGesture(toolbarDismissSwipe)
                .confirmationDialog("Window Options", isPresented: $showingOptions, titleVisibility: .visible) {
                    windowActions(for: window)
                } message: {
                    Text(model.connectionSummary)
                }
        }
    }

    /// Installed on the native controls themselves, so a drag beginning over the bar
    /// does not depend on the remote surface receiving that touch.
    private var toolbarDismissSwipe: some Gesture {
        DragGesture(minimumDistance: 10).onEnded { value in
            guard let edge = verticalEdge, abs(value.translation.width) > 30,
                  abs(value.translation.width) > abs(value.translation.height) else { return }
            let outward = edge == .trailing ? value.translation.width > 0 : value.translation.width < 0
            if outward { withAnimation(.snappy) { chromeVisible = false } }
        }
    }

    /// The presenting toolbar button anchors these system actions beside the controls.
    @ViewBuilder private func windowActions(for window: RemoteWindow) -> some View {
        Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { chromeVisible = false }
        Button("Exit App Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") {
            model.session?.exitFullscreen(window, frame: window.frame)
            withAnimation(.snappy) { chromeVisible = true }
        }
        if model.agents.available {
            Button("Ask Agent About This Window", systemImage: "sparkle") { askingAbout = window }
        }
        if let video = model.media.available, window.appClass?.name.lowercased().contains("chromium") == true {
            Button("Play on iPhone or Apple TV", systemImage: "play.tv") { Task { await model.media.playHere(video) } }
        }
        Button("Redraw", systemImage: "arrow.clockwise") { model.session?.refresh(window) }
        Button("Close Window", systemImage: "xmark", role: .destructive) { model.session?.close(window) }
    }

    /// Fill the shown area with the window, in Linux pixels.
    private func fit(_ window: RemoteWindow, to size: CGSize) {
        guard model.presentedWindowID == window.id, size.width > 0, size.height > 0, let session = model.session else { return }
        model.windowCardResized(to: size)
        let target = DeviceViewport.guestFrame(size: size, pixelsPerPoint: model.pixelsPerPoint)
        if window.frame != target {
            var state = ["maximized": false]
            if model.externalDisplayActive && window.isFullscreen { state["fullscreen"] = false }
            session.configure(window, frame: target, state: state)
        }
        session.focus(window)
    }

    /// A dialog (not a menu or tooltip) is moved, and shrunk if it must be, to sit centred in
    /// the shown area: apps size and place dialogs for a desktop, and half of one off the
    /// edge of a phone cannot be reached. The server is told, so clicks land where it shows.
    private func fitDialog(_ dialog: RemoteWindow, over parent: RemoteWindow, in size: CGSize) {
        guard model.presentedWindowID == parent.id, !dialog.isOverrideRedirect, let session = model.session,
              size.width > 0, size.height > 0 else { return }
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

    /// Use the same mapping as tiles: the actual fitted parent surface, then each
    /// descendant's displayed frame, including clamping a menu before placing its submenu.
    private func popupFrames(_ popups: [RemoteWindow], over parent: RemoteWindow, size: CGSize) -> [Int: CGRect] {
        let scale = model.pixelsPerPoint
        let root = DesktopGeometry.surfaceFrame(
            natural: CGSize(width: parent.frame.width / scale, height: parent.frame.height / scale),
            available: size, resizing: false)
        let windows = Dictionary(uniqueKeysWithValues: ([parent] + popups).map {
            ($0.id, DesktopGeometry.WindowGeometry(frame: $0.frame, parent: $0.transientFor))
        })
        return DesktopGeometry.popupFrames(windows: windows, rootFrames: [parent.id: root],
                                          viewport: CGRect(origin: .zero, size: size), pixelsPerPoint: scale)
    }
}

/// Reads the toolbar environment inside the card's navigation stack, where the system
/// supplies its actual edge. Only a vertical bar frees the top/bottom container insets;
/// both horizontal safe edges and the software keyboard remain protected.
private struct WindowCardViewport<Content: View>: View {
    @Environment(\.toolbarVerticalEdgeIfAvailable) private var barEdge
    let controlsVisible: Bool
    @Binding var verticalEdge: HorizontalEdge?
    let content: (GeometryProxy) -> Content

    var body: some View {
        GeometryReader(content: content)
            .ignoresSafeArea(.container, edges: ignoredEdges)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onAppear { verticalEdge = barEdge }
            .onChange(of: barEdge) { _, edge in
                // Keep the reveal edge while hidden; read current placement again
                // when controls are visible after a fold or orientation change.
                if controlsVisible || edge != nil { verticalEdge = edge }
            }
            .onChange(of: controlsVisible) { _, visible in
                if visible { verticalEdge = barEdge }
            }
    }

    private var ignoredEdges: Edge.Set {
        if !controlsVisible { return .all }
        return barEdge == nil ? [] : .all
    }
}

/// An interactive remote window surface.
struct RemoteWindowCanvas: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(\.laptopInputOwned) private var laptopInputOwned
    let window: RemoteWindow
    let keyboardVisible: Bool

    func makeUIView(context: Context) -> YardSurfaceView {
        let view = YardSurfaceView(content: RemoteWindowView(session: model.session, window: window))
        view.content.pixelsPerPoint = model.pixelsPerPoint
        let model = model
        view.content.onKeyboardWanted = { wanted in
            if model.keyboardVisible != wanted { model.keyboardVisible = wanted }
        }
        return view
    }

    func updateUIView(_ view: YardSurfaceView, context: Context) {
        view.content.session = model.session
        view.content.pixelsPerPoint = model.pixelsPerPoint
        if view.content.remoteWindow?.id != window.id { view.content.attach(window) }
        view.natural = CGSize(width: window.frame.width / model.pixelsPerPoint,
                              height: window.frame.height / model.pixelsPerPoint)
        view.laptopPoint = laptopInputOwned ? LaptopPointer.shared.point(in: window, session: model.session) : nil
        if keyboardVisible && !laptopInputOwned, !view.content.isFirstResponder {
            DispatchQueue.main.async { view.content.becomeFirstResponder() }
        } else if (!keyboardVisible || laptopInputOwned), view.content.isFirstResponder {
            DispatchQueue.main.async { view.content.resignFirstResponder() }
        }
    }
}

/// A live preview for Home: same surface, no input, drawn `width` points wide.
struct RemoteWindowPreview: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    var width: CGFloat = 150

    func makeUIView(context: Context) -> RemoteWindowView {
        let view = RemoteWindowView(session: nil, window: window)
        view.isInteractive = false
        view.pixelsPerPoint = max(1, window.frame.width / width)
        view.pacer = model.session // a live preview is paced like any window on screen
        view.showsVideo = false // the window's own screen plays its videos
        return view
    }

    func updateUIView(_ view: RemoteWindowView, context: Context) {
        view.pacer = model.session
        if view.remoteWindow?.id != window.id { view.attach(window) }
        view.pixelsPerPoint = max(1, window.frame.width / width)
    }
}
