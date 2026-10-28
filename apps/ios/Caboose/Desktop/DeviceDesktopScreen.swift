import CabooseKit
import SwiftUI
import UIKit

/// The Desktop tab: the computer's whole desktop on this screen, its windows tiled in
/// Switchyard (or, on an iPad that chooses Free, floating with the dock and Launchpad); or,
/// while a TV shows the desktop, this phone as its trackpad.
///
/// Its actions sit in the toolbar, so on iPhone Duo they join the tab bar in the vertical bar
/// on the side, which stays fully shown as on every tab. The desktop fills everything beside
/// the vertical bar, or between horizontal bars, and the computer lays its windows out for
/// exactly that space; when the bars change, so does the desktop. Full Screen opens the focused app as a native card. Behind it all, under the
/// bar as well, is the desktop's photograph with a sheer of the brand gradient.
struct DesktopScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showAirPlay = false

    var body: some View {
        NavigationStack {
            Group {
                if model.phase != .ready {
                    ComputerStateView()
                } else if model.externalDisplayActive {
                    TrackpadScreen(desktop: model.desktop)
                } else {
                    DesktopStage(fullScreen: immersive)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ShellBackground() }
            .navigationTitle("Desktop")
            .navigationBarTitleDisplayMode(.inline)
            // The desktop needs the height more than a title: with the vertical bar the top
            // edge then belongs to the desktop alone.
            .toolbar(removing: .title)
            .toolbar {
                if model.phase == .ready { actions }
                ComputerToolbar()
            }
            .keepsTabBarInVerticalBar()
            .toolbarVisibility(immersive ? .hidden : .automatic, for: .navigationBar, .tabBar)
            .statusBarHidden(immersive)
            .persistentSystemOverlays(immersive ? .hidden : .automatic)
            .animation(.snappy, value: immersive)
            .sheet(isPresented: $showAirPlay) {
                AirPlaySheet().environment(model)
                    .presentationDetents([.medium])
            }
        }
    }

    /// A Switchyard window covering the screen: the bars,
    /// the status bar and the home indicator step aside.
    private var immersive: Bool {
        model.yardActive && !model.externalDisplayActive && model.yard.coverWindow != nil
    }

    /// The desktop's own actions. Agents and Apps are tabs beside them and Launchpad is in
    /// the dock, so they are not repeated here. Full Screen gives way first when room runs out.
    @ToolbarContentBuilder private var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !model.keyboardVisible {
                Button("Keyboard", systemImage: "keyboard") { model.keyboardVisible = true }
            }
            Button("AirPlay", systemImage: model.airPlay.current != nil ? "airplay.audio" : "airplay.video") { showAirPlay = true }
        }
        if !model.externalDisplayActive, UIDevice.current.userInterfaceIdiom == .pad {
            ToolbarItem(placement: .topBarTrailing) {
                @Bindable var model = model
                Picker("Arrangement", selection: $model.deviceDesktopStyle) {
                    Label("Tiled", systemImage: "rectangle.split.3x1").tag(AppModel.DeviceDesktopStyle.tiled)
                    Label("Free", systemImage: "macwindow.on.rectangle").tag(AppModel.DeviceDesktopStyle.free)
                }
                .pickerStyle(.menu)
            }
        }
        if !model.externalDisplayActive {
            if #available(iOS 27.0, *) {
                fullScreenItem.visibilityPriority(.low)
            } else {
                fullScreenItem
            }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        if #available(iOS 27.0, *) {
            // The system's overflow menu, with whatever else did not fit.
            ToolbarOverflowMenu {
                Button("Wallpaper", systemImage: "photo.on.rectangle") { model.wallpaperPickerPresented = true }
                if WallpaperStore.shared.choice.usesLibrary {
                    Button("Next Photograph", systemImage: "arrow.triangle.2.circlepath") { WallpaperStore.shared.next() }
                }
            }
        }
    }

    private var fullScreenItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                if let window = model.window(model.yard.layout.focused) { model.show(windowID: window.id) }
            }
                .disabled(!model.yardActive || model.window(model.yard.layout.focused) == nil)
                .labelStyle(.iconOnly)
        }
    }


}

/// The phone's own desktop, edge to edge. Beside a vertical bar it takes the full height and
/// everything up to the bar; with horizontal bars, the space between them; in full screen,
/// the whole display. The computer is configured for exactly that size.
private struct DesktopStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.toolbarVerticalEdgeIfAvailable) private var barEdge
    let fullScreen: Bool

    var body: some View {
        GeometryReader { proxy in
            Group {
                if model.deviceDesktopStyle == .tiled {
                    SwitchyardView(yard: model.yard)
                } else {
                    ZStack {
                        DesktopView(desktop: model.desktop, fillsScreen: false)
                        DesktopTouchArea(desktop: model.desktop, keyboardVisible: model.keyboardVisible)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .onAppear { model.desktopStageResized(to: proxy.size) }
            .onChange(of: proxy.size) { _, size in model.desktopStageResized(to: size) }
            .onChange(of: barEdge) { _, _ in model.desktopStageResized(to: proxy.size) }
            .onChange(of: model.selectedTab) { _, tab in
                if tab == .desktop { model.desktopStageResized(to: proxy.size) }
            }
        }
        .ignoresSafeArea(edges: ignoredEdges)
    }

    private var ignoredEdges: Edge.Set {
        if fullScreen { return .all }
        switch barEdge {
        case .trailing: return [.top, .bottom]
        case .leading: return [.top, .bottom]
        case nil: return []
        }
    }
}

extension EnvironmentValues {
    /// The edge of the vertical bar (iPhone Duo, iOS 27.1), or nil where bars are horizontal.
    var toolbarVerticalEdgeIfAvailable: HorizontalEdge? {
        if #available(iOS 27.1, *) { toolbarVerticalEdge } else { nil }
    }
}

/// Touch straight on the desktop: a tap clicks where it lands, a drag moves what it starts
/// on (a title bar moves its window, a corner resizes, content drags inside the app), two
/// fingers scroll, a two-finger tap or a long press right-clicks, two taps double-click.
/// An iPad pointer hovers and clicks like a Mac's. Keys go to the frontmost window.
struct DesktopTouchArea: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel
    let keyboardVisible: Bool

    func makeUIView(context: Context) -> DesktopTouchSurface {
        let view = DesktopTouchSurface()
        view.desktop = desktop
        view.model = model
        return view
    }

    func updateUIView(_ view: DesktopTouchSurface, context: Context) {
        view.desktop = desktop
        view.model = model
        if keyboardVisible && !model.windowCardOwnsGeometry, !view.isFirstResponder { DispatchQueue.main.async { view.becomeFirstResponder() } }
        if (!keyboardVisible || model.windowCardOwnsGeometry), view.isFirstResponder { DispatchQueue.main.async { view.resignFirstResponder() } }
    }
}

final class DesktopTouchSurface: RemoteTextInputView {
    weak var desktop: DesktopModel?
    weak var model: AppModel?

    private var began: TimeInterval = 0
    private var travel: CGFloat = 0
    private var touchOrigin = CGPoint.zero
    private var maxFingers = 0
    private var dragging = false
    private var contextOpened = false
    private var press = DirectPointerPress()
    private var holdTimer: Timer?
    private var lastCentroid: CGPoint?
    private var lastTap: (time: TimeInterval, point: CGPoint)?
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var session: (any DisplaySession)? { model?.session }

    private func live(_ event: UIEvent?) -> [UITouch] {
        event?.touches(for: self)?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? []
    }

    private func centroid(_ touches: [UITouch]) -> CGPoint? {
        guard !touches.isEmpty else { return nil }
        let points = touches.map { $0.location(in: self) }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    /// Puts the cursor (seen or not) exactly under the finger.
    private func point(at location: CGPoint) {
        guard let desktop else { return }
        desktop.move(by: CGPoint(x: location.x - desktop.cursor.x, y: location.y - desktop.cursor.y), session: session)
    }

    private func open(_ id: String) {
        guard let model, let app = model.apps.first(where: { $0.id == id }) else { return }
        model.openOnDesktop(app)
    }

    @objc private func hover(_ gesture: UIHoverGestureRecognizer) {
        guard let desktop else { return }
        switch gesture.state {
        case .began, .changed:
            desktop.pointerHovering = true
            point(at: gesture.location(in: self))
        default:
            desktop.pointerHovering = false
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        press.cancel()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelHold() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = live(event)
        if maxFingers == 0 {
            began = event?.timestamp ?? 0
            travel = 0
            dragging = false
            contextOpened = false
            cancelHold()
            if let first = touches.first, touches.first?.type != .indirectPointer { desktop?.pointerHovering = false; point(at: first.location(in: self)) }
            else if let first = touches.first { point(at: first.location(in: self)) }
        }
        maxFingers = max(maxFingers, fingers.count)
        lastCentroid = centroid(fingers)
        if maxFingers == 1, let point = lastCentroid { touchOrigin = point }
        if maxFingers == 1, let first = touches.first, first.type == .direct {
            press.begin(at: first.location(in: self), time: ProcessInfo.processInfo.systemUptime)
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self, let desktop = self.desktop, !self.dragging,
                      let point = self.press.context(at: ProcessInfo.processInfo.systemUptime) else { return }
                self.contextOpened = true
                self.lastTap = nil
                self.point(at: point)
                desktop.click(button: 3, session: self.session, open: self.open)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } else { cancelHold() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = live(event)
        guard !contextOpened else { return }
        guard let desktop, let now = centroid(fingers), let last = lastCentroid else { return }
        let delta = CGPoint(x: now.x - last.x, y: now.y - last.y)
        lastCentroid = now
        travel = max(travel, hypot(now.x - touchOrigin.x, now.y - touchOrigin.y))
        press.move(to: now)
        if maxFingers >= 2 {
            cancelHold()
            // Content follows the fingers, like any iOS scroll view.
            desktop.scroll(by: CGPoint(x: -delta.x, y: -delta.y), session: session)
            return
        }
        if !dragging, travel > 8 {
            dragging = true
            cancelHold()
            desktop.beginDrag(session: session)
        }
        if dragging, let finger = fingers.first { point(at: finger.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard live(event).isEmpty, let desktop else { return }
        let now = event?.timestamp ?? 0
        let duration = now - began
        defer { maxFingers = 0; lastCentroid = nil; cancelHold() }
        if contextOpened { return }
        if dragging {
            desktop.endDrag(session: session)
            dragging = false
            return
        }
        guard travel < 12 else { return }
        if maxFingers >= 2 {
            if duration < 0.4 { desktop.click(button: 3, session: session, open: open); haptics.impactOccurred() }
            return
        }
        if duration > 0.5 { return }
        if let lastTap, now - lastTap.time < 0.35, hypot(desktop.cursor.x - lastTap.point.x, desktop.cursor.y - lastTap.point.y) < 24 {
            desktop.doubleClick(session: session, open: open)
            self.lastTap = nil
        } else {
            desktop.click(session: session, open: open)
            lastTap = (now, desktop.cursor)
        }
        resetTyping()
        prefersProse = autocorrectChoice ?? !RemoteWindowView.isCodeApp(focusedWindow)
        haptics.impactOccurred()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelHold()
        if dragging { desktop?.endDrag(session: session) }
        dragging = false
        maxFingers = 0
        lastCentroid = nil
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    private var focusedWindow: RemoteWindow? {
        guard let session, let desktop else { return nil }
        return desktop.stacking.reversed().compactMap { session.windows[$0] }.first { !$0.isAuxiliary && desktop.isVisible($0.id) }
    }

    override func insertText(_ text: String) {
        let modified = hasStickyModifiers
        super.insertText(text)
        if !modified, (text == "\n" || text == "\r" || text == "\r\n"), !RemoteWindowView.isCodeApp(focusedWindow) {
            dismissKeyboard()
        }
    }

    override func dismissKeyboard() {
        model?.keyboardVisible = false
        super.dismissKeyboard()
    }

    override func send(_ edits: [TypingBuffer.Edit]) { session?.edit(edits, in: focusedWindow) }
    override var sendsMarkedTextAsPreedit: Bool { session?.composesText ?? false }
    override func sendPreedit(_ text: String, selection: NSRange) { session?.compose(text, selection: selection, in: focusedWindow) }
    override func sendKey(_ stroke: KeyStroke, modifiers: [String]) {
        session?.key(stroke, pressed: true, in: focusedWindow, extraModifiers: modifiers)
        session?.key(stroke, pressed: false, in: focusedWindow, extraModifiers: modifiers)
    }

}
