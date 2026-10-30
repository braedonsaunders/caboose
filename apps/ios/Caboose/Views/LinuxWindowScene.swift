import CabooseKit
import Combine
import GameController
import SwiftUI
import UIKit

/// One Linux window in an iPadOS window of its own: a scene of the `LinuxWindowRef` window
/// group, opened by Open in New Window or by dragging a window out of the app.
///
/// The Linux window fills the iPadOS window below a bar with its title, Keyboard and Window
/// Options, with the same touch, pointer, keyboard, text and Pencil input as an app card, and
/// its menus and dialogs inside it. Resizing the iPadOS window resizes the Linux window, and
/// the Linux window's size limits become the iPadOS window's. While this scene shows it, the
/// in-app desktop, its tiles and app cards leave the window to it. Closing the iPadOS window
/// returns the Linux window to the desktop, still open; the Linux window closing closes this
/// iPadOS window. A window restored after a relaunch shows its Linux window again once the
/// computer has announced it, or says it is gone.
struct LinuxWindowScene: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Binding var ref: LinuxWindowRef?
    /// The UIKit scene and window this view is in, from `SceneProbe`.
    @State private var host = SceneHost()
    @State private var sceneID: String?
    /// The Linux window has been shown in this scene, so its going means it closed.
    @State private var shown = false
    @State private var keyboardVisible = false
    @State private var cardFit = CardWindowFit()
    /// The iPadOS window's size, and the part of it the Linux window fills.
    @State private var sceneSize: CGSize = .zero
    @State private var contentSize: CGSize = .zero
    /// A new size is on its way: the last picture stretches over the window meanwhile.
    @State private var settling: UUID?
    @State private var lastFit: TimeInterval = -.infinity
    @State private var fitTask: Task<Void, Never>?

    /// Live resizing sends the Linux window a new size at most this often.
    private static let fitInterval: TimeInterval = 0.12

    init(ref: Binding<LinuxWindowRef?>) { _ref = ref }

    var body: some View {
        NavigationStack {
            stage
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { controls }
        }
        .background {
            SceneProbe(connected: { window in
                host.window = window
                sceneID = window.windowScene?.session.persistentIdentifier
                applySceneState()
            }, disconnected: { id in
                model.releaseWindowScene(id)
            }, becameKey: {
                activate()
            }, sizeChanged: { size in
                sceneSize = size
            })
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .tint(Brand.amber)
        .onContinueUserActivity(LinuxWindowRef.activityType) { activity in
            // A window dragged out of the app arrives as the activity that made this scene.
            if ref == nil, let dropped = LinuxWindowRef(activityUserInfo: activity.userInfo) { ref = dropped }
        }
        .onChange(of: Claim(scene: sceneID, ref: ref), initial: true) { _, claim in take(claim) }
        .onChange(of: Standing(scene: sceneID, presence: presence), initial: true) { _, standing in follow(standing.presence) }
        .onChange(of: title) { _, _ in applySceneState() }
        .onChange(of: limits) { _, _ in applySceneState() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { activate() } }
        .onReceive(NotificationCenter.default.publisher(for: .GCKeyboardDidConnect)) { _ in
            if scenePhase == .active, window != nil { keyboardVisible = true }
        }
        .onDisappear {
            fitTask?.cancel()
            if let sceneID { model.releaseWindowScene(sceneID) }
        }
    }

    // MARK: The window

    /// This scene's Linux window, while the session has it.
    private var window: RemoteWindow? {
        guard let ref, model.credentials?.fileDomainIdentifier == ref.computer, let session = model.session,
              session.epoch == ref.epoch, let window = session.windows[ref.window], !window.isAuxiliary else { return nil }
        return window
    }

    private var presence: LinuxWindowRef.Presence? {
        guard let ref else { return nil }
        let session = model.session
        return ref.presence(computer: model.credentials?.fileDomainIdentifier, epoch: session?.epoch,
                            ready: session?.state == .ready, announced: (session?.windowsAnnounced ?? 0) > 0,
                            windowExists: window != nil)
    }

    private var title: String {
        if let window { return window.title.isEmpty ? model.appName(for: window) : window.title }
        return ref?.name ?? "Window"
    }

    /// The Linux window's size limits as the iPadOS window's, with the bar's room added.
    private var limits: SceneSizeLimits {
        let chrome = contentSize == .zero || sceneSize == .zero ? CGSize.zero
            : CGSize(width: max(0, sceneSize.width - contentSize.width), height: max(0, sceneSize.height - contentSize.height))
        return SceneSizeLimits.limits(minimum: window?.minimumSize, maximum: window?.maximumSize,
                                      pixelsPerPoint: model.pixelsPerPoint, chrome: chrome)
    }

    @ViewBuilder private var stage: some View {
        ZStack(alignment: .top) {
            Backdrop()
            if let window {
                GeometryReader { proxy in surface(for: window, size: proxy.size) }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            } else if ref == nil {
                unavailable("No Window", detail: "This window has no Linux window to show.")
            } else {
                switch presence {
                case .gone: unavailable(ref?.name ?? "Window", detail: "This window is no longer open on your computer.")
                case .waiting where model.phase == .ready:
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .waiting: ComputerStateView()
                case .present, .otherComputer, nil: Color.clear
                }
            }
            ConnectionBanner()
        }
    }

    private func unavailable(_ name: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(name, systemImage: "macwindow")
        } description: {
            Text(detail)
        } actions: {
            Button("Close") { closeScene() }
                .buttonStyle(.glassProminent)
        }
    }

    @ToolbarContentBuilder private var controls: some ToolbarContent {
        if let window {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !keyboardVisible {
                    Button("Keyboard", systemImage: "keyboard") { keyboardVisible = true }
                }
                Menu("Window Options", systemImage: "ellipsis") {
                    Button("Move to Desktop", systemImage: "rectangle.on.rectangle") { model.moveToDesktop(window.id) }
                    Button("Exit App Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") {
                        model.session?.exitFullscreen(window, frame: DeviceViewport.guestFrame(size: contentSize, pixelsPerPoint: model.pixelsPerPoint))
                    }
                    Button("Redraw", systemImage: "arrow.clockwise") { model.session?.refresh(window) }
                    Divider()
                    Button("Close Window", systemImage: "xmark", role: .destructive) { model.session?.close(window) }
                }
            }
        }
    }

    // MARK: Surface

    /// The window and its menus and dialogs, as in an app card.
    private func surface(for window: RemoteWindow, size: CGSize) -> some View {
        let popups = popups(of: window)
        // Keys go to the topmost dialog, if one is up, else to the window.
        let keyTarget = popups.last { !$0.isOverrideRedirect }?.id ?? window.id
        let frames = popupFrames(popups, over: window, size: size)
        return ZStack(alignment: .topLeading) {
            RemoteWindowCanvas(window: window, keyboardVisible: keyboardVisible && keyTarget == window.id,
                               stretch: settling != nil, keyboardWanted: keyboardWanted)
                .frame(width: size.width, height: size.height)
                .modifier(WindowDrop(window: window, pixelsPerPoint: model.pixelsPerPoint))
            ForEach(popups) { popup in
                if let frame = frames[popup.id] {
                    RemoteWindowCanvas(window: popup, keyboardVisible: keyboardVisible && keyTarget == popup.id,
                                       keyboardWanted: keyboardWanted)
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
        .onAppear { requestFit(window, size) }
        .onChange(of: size) { _, size in requestFit(window, size) }
        .onChange(of: window.frame) { _, frame in
            if settling != nil, frame.size == DeviceViewport.guestFrame(size: size, pixelsPerPoint: model.pixelsPerPoint).size {
                settling = nil
            }
            requestFit(window, size)
        }
    }

    /// A tap's answer: the software keyboard comes and goes with text fields, while a
    /// hardware keyboard keeps the window as the place keys go.
    private var keyboardWanted: (Bool) -> Void {
        { wanted in keyboardVisible = wanted || GCKeyboard.coalesced != nil }
    }

    /// The window's menus, popups and dialogs, and popups of its app that name no parent.
    private func popups(of window: RemoteWindow) -> [RemoteWindow] {
        guard let windows = model.session?.windows else { return [] }
        var parents: [Int: Int] = [:]
        for candidate in windows.values { if let parent = candidate.transientFor { parents[candidate.id] = parent } }
        let own = DetachedWindows.withDescendants([window.id], parents: parents)
        let app = window.appClass?.name
        return windows.values.filter { candidate in
            candidate.isAuxiliary && candidate.id != window.id
                && (own.contains(candidate.id) || (candidate.transientFor == nil && app != nil && candidate.appClass?.name == app))
        }
        .sorted { $0.id < $1.id }
    }

    /// The same mapping as cards and tiles: the fitted window, then each descendant's frame.
    private func popupFrames(_ popups: [RemoteWindow], over parent: RemoteWindow, size: CGSize) -> [Int: CGRect] {
        let scale = model.pixelsPerPoint
        let root = DesktopGeometry.surfaceFrame(
            natural: CGSize(width: parent.frame.width / scale, height: parent.frame.height / scale),
            available: size, resizing: settling != nil)
        let windows = Dictionary(uniqueKeysWithValues: ([parent] + popups).map {
            ($0.id, DesktopGeometry.WindowGeometry(frame: $0.frame, parent: $0.transientFor))
        })
        return DesktopGeometry.popupFrames(windows: windows, rootFrames: [parent.id: root],
                                          viewport: CGRect(origin: .zero, size: size), pixelsPerPoint: scale)
    }

    /// A dialog of this window sits centred over it, made smaller if the window is, and the
    /// server is told, so taps land where it shows.
    private func fitDialog(_ dialog: RemoteWindow, over parent: RemoteWindow, in size: CGSize) {
        guard !dialog.isOverrideRedirect, dialog.transientFor != nil, let session = model.session,
              session.windows[dialog.id] === dialog, size.width > 0, size.height > 0 else { return }
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

    // MARK: Size

    /// Sends the Linux window this window's size, at most every `fitInterval` while it is
    /// resized, the last size always.
    private func requestFit(_ window: RemoteWindow, _ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if contentSize != size { contentSize = size }
        fitTask?.cancel()
        let wait = Self.fitInterval - (ProcessInfo.processInfo.systemUptime - lastFit)
        guard wait > 0 else { return fit(window, size) }
        fitTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            fit(window, size)
        }
    }

    private func fit(_ window: RemoteWindow, _ size: CGSize) {
        let now = ProcessInfo.processInfo.systemUptime
        lastFit = now
        // An app's own full screen takes the computer's whole display; its picture is fitted here.
        guard !window.isFullscreen, let session = model.session, session.state == .ready,
              session.windows[window.id] === window else { return }
        let target = DeviceViewport.guestFrame(size: size, pixelsPerPoint: model.pixelsPerPoint)
        guard cardFit.shouldCorrect(frame: window.frame, target: target, now: now) else { return }
        if window.frame.size != target.size { settle() }
        session.configure(window, frame: target, state: ["maximized": false])
    }

    /// Stretches the last picture until the app redraws at the new size, or for a moment at
    /// most: an app that keeps its own size is then shown as it is.
    private func settle() {
        let token = UUID()
        settling = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if settling == token { settling = nil }
        }
    }

    // MARK: Scene

    /// Keys reach this window while its iPadOS window is the one in use.
    private func activate() {
        guard let window, let session = model.session, session.state == .ready else { return }
        session.focus(window)
        if GCKeyboard.coalesced != nil { keyboardVisible = true }
    }

    /// The iPadOS window's title (App Exposé, the window menu) and size limits follow the
    /// Linux window's.
    private func applySceneState() {
        guard let scene = host.window?.windowScene else { return }
        scene.title = title
        guard let restrictions = scene.sizeRestrictions else { return }
        let limits = limits
        if restrictions.minimumSize != limits.minimum { restrictions.minimumSize = limits.minimum }
        if restrictions.maximumSize != limits.maximum { restrictions.maximumSize = limits.maximum }
    }

    /// This scene shows `claim.ref`. A window already open in another iPadOS window stays
    /// there: that one comes forward and this one closes.
    private func take(_ claim: Claim) {
        guard let scene = claim.scene, let ref = claim.ref else { return }
        if let other = model.claimWindowScene(ref, scene: scene) {
            model.bringForward(scene: other)
            closeScene()
        }
    }

    private func follow(_ presence: LinuxWindowRef.Presence?) {
        switch presence {
        case .present:
            if !shown {
                shown = true
                if host.window?.isKeyWindow == true { activate() }
            }
        case .gone:
            // Closed on the computer: its window goes too. A window restored after the Linux
            // window went says so instead.
            if shown { closeScene() }
        case .otherComputer:
            closeScene()
        case .waiting, nil:
            break
        }
        applySceneState()
    }

    /// Closes this iPadOS window; the Linux window, if it is still open, is the desktop's again.
    private func closeScene() {
        if let sceneID { model.releaseWindowScene(sceneID) }
        guard let session = host.window?.windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
    }

    private struct Claim: Equatable {
        var scene: String?
        var ref: LinuxWindowRef?
    }

    private struct Standing: Equatable {
        var scene: String?
        var presence: LinuxWindowRef.Presence?
    }
}

/// The UIKit window a SwiftUI scene's view is in, held weakly.
@MainActor
final class SceneHost {
    weak var window: UIWindow?
}

/// Reports the UIKit window and scene a SwiftUI view is in: when it connects and goes, when
/// its window becomes key, and the window's size.
struct SceneProbe: UIViewRepresentable {
    var connected: (UIWindow) -> Void
    var disconnected: (String) -> Void = { _ in }
    var becameKey: () -> Void = {}
    var sizeChanged: (CGSize) -> Void = { _ in }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        update(view)
        return view
    }

    func updateUIView(_ view: Probe, context: Context) { update(view) }

    private func update(_ view: Probe) {
        view.connected = connected
        view.disconnected = disconnected
        view.becameKey = becameKey
        view.sizeChanged = sizeChanged
    }

    final class Probe: UIView {
        var connected: (UIWindow) -> Void = { _ in }
        var disconnected: (String) -> Void = { _ in }
        var becameKey: () -> Void = {}
        var sizeChanged: (CGSize) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []
        private var lastSize: CGSize = .zero

        override func didMoveToWindow() {
            super.didMoveToWindow()
            isUserInteractionEnabled = false
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameKey() }
            })
            if let scene = window.windowScene {
                let id = scene.session.persistentIdentifier
                observers.append(center.addObserver(forName: UIScene.didDisconnectNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.disconnected(id) }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                self.connected(window)
                self.reportSize()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            reportSize()
        }

        private func reportSize() {
            guard let size = window?.bounds.size, size != lastSize else { return }
            lastSize = size
            DispatchQueue.main.async { [weak self] in self?.sizeChanged(size) }
        }
    }
}

extension View {
    /// Dragging this window out of the app opens it in an iPadOS window of its own where it
    /// is dropped. Only where windows can have their own.
    @ViewBuilder
    func linuxWindowDrag(_ window: RemoteWindow, model: AppModel) -> some View {
        if model.supportsWindowScenes {
            onDrag {
                let provider = NSItemProvider()
                guard let ref = model.windowRef(for: window), !model.detachedWindowIDs.contains(window.id) else { return provider }
                let activity = NSUserActivity(activityType: LinuxWindowRef.activityType)
                activity.title = ref.name
                activity.userInfo = ref.activityUserInfo
                activity.targetContentIdentifier = LinuxWindowRef.activityType
                provider.registerObject(activity, visibility: .all)
                provider.suggestedName = ref.name
                return provider
            }
        } else {
            self
        }
    }
}
