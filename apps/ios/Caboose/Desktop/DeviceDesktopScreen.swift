import CabooseKit
import SwiftUI
import UIKit

/// The Desktop tab: the computer's whole desktop on this screen, its windows tiled in
/// Switchyard (or, on an iPad that chooses Free, floating with the dock and Launchpad); or,
/// while a TV shows the desktop, this phone as its trackpad.
///
/// Portrait puts controls and app navigation in a compact panel above the dock, with
/// no reserved strip. Landscape keeps its native toolbar or custom rail. Full Screen
/// opens the focused app as a native card; there is no separate desktop screen.
struct DesktopScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.portraitDesktopChrome) private var portraitDesktop
    @Environment(\.shellTabPlacement) private var tabPlacement
    @State private var showAirPlay = false
    @State private var laptopActive = false

    var body: some View {
        NavigationStack {
            Group {
                if model.phase != .ready {
                    ComputerStateView()
                } else {
                    LaptopContainer(activeChanged: { laptopActive = $0 }) { laptop in
                        if model.externalDisplayActive {
                            if laptop { LaptopExternalOverview() }
                            else { TrackpadScreen(desktop: model.desktop) }
                        } else {
                            DesktopStage(fullScreen: immersive)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: portraitDesktop && !laptopActive ? [.top, .bottom] : [])
            .background { ShellBackground() }
            .navigationTitle("Desktop")
            .navigationBarTitleDisplayMode(.inline)
            // The desktop needs the height more than a title: with the vertical bar the top
            // edge then belongs to the desktop alone.
            .toolbar(removing: .title)
            .toolbar {
                if !laptopActive && !portraitDesktop && tabPlacement != .sidebar {
                    if model.phase == .ready { actions }
                    ComputerToolbar()
                }
            }
            .keepsTabBarInVerticalBar()
            .toolbarVisibility(immersive || laptopActive || portraitDesktop || tabPlacement == .sidebar ? .hidden : .automatic, for: .navigationBar)
            // A child automatic preference must not restore the system bar beneath
            // the shell's custom tabs after rotation.
            .toolbarVisibility(immersive || laptopActive || portraitDesktop || tabPlacement != .system ? .hidden : .automatic, for: .tabBar)
            .statusBarHidden(immersive || laptopActive || portraitDesktop || tabPlacement == .sidebar)
            .persistentSystemOverlays(immersive || laptopActive ? .hidden : .automatic)
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
            LaptopModeMenu()
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
                    Button("Next Wallpaper", systemImage: "arrow.triangle.2.circlepath") { WallpaperStore.shared.next() }
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

/// Desktop actions share the custom shell rail with its tabs when the system has
/// horizontal bars. The native vertical toolbar continues to own landscape controls.
struct DesktopRailControls: View {
    @Environment(AppModel.self) private var model
    @State private var showAirPlay = false
    var compact = false

    var body: some View {
        let layout = compact ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            if model.phase == .ready {
                Menu {
                    LaptopModeMenu()
                    Button("AirPlay", systemImage: "airplay.video") { showAirPlay = true }
                    if !model.externalDisplayActive, UIDevice.current.userInterfaceIdiom == .pad {
                        @Bindable var model = model
                        Picker("Arrangement", selection: $model.deviceDesktopStyle) {
                            Label("Tiled", systemImage: "rectangle.split.3x1").tag(AppModel.DeviceDesktopStyle.tiled)
                            Label("Free", systemImage: "macwindow.on.rectangle").tag(AppModel.DeviceDesktopStyle.free)
                        }
                    }
                    Button("Wallpaper", systemImage: "photo.on.rectangle") { model.wallpaperPickerPresented = true }
                    if WallpaperStore.shared.choice.usesLibrary {
                        Button("Next Wallpaper", systemImage: "arrow.triangle.2.circlepath") { WallpaperStore.shared.next() }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 56, height: 44) }
                .accessibilityLabel("Desktop controls")
                Button("Keyboard", systemImage: "keyboard") { model.keyboardVisible.toggle() }
                    .frame(width: 56, height: 44)
            }
            Button("Computer", systemImage: "gearshape") { model.settingsPresented = true }
                .frame(width: 56, height: 44)
            LifecycleMenu().frame(width: 56, height: 44)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .sheet(isPresented: $showAirPlay) {
            AirPlaySheet().environment(model).presentationDetents([.medium])
        }
    }
}

/// A single bottom control owns the portrait presentation. The popover is attached to
/// the button itself; its scrollable content is bounded, including with Dynamic Type.
struct DesktopPanelButton: View {
    @Environment(AppModel.self) private var model
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Desktop controls and navigation")
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityHint("Opens desktop controls and app navigation")
        .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            ScrollView { panel }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 288, height: 240)
                // Even a narrow phone keeps the panel anchored and dismissible, rather
                // than adapting it into a full-screen presentation.
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: model.selectedTab) { _, _ in presented = false }
        .onDisappear { presented = false }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Desktop").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { presented = false }
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Close desktop controls")
            }
            DesktopRailControls(compact: true)
            Divider()
            ShellTabButtons(axis: .horizontal, showsTitles: true)
        }
        .padding(16)
        .frame(width: 288)
        .accessibilityAction(.escape) { presented = false }
    }
}

/// The phone's own desktop, edge to edge. Beside a vertical bar it takes the full height and
/// everything up to the bar; with horizontal bars, the space between them; in full screen,
/// the whole display. The computer is configured for exactly that size.
private struct DesktopStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.toolbarVerticalEdgeIfAvailable) private var barEdge
    @Environment(\.laptopInputOwned) private var laptopInputOwned
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
                        DesktopKeyCommands(desktop: model.desktop)
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
    @Environment(\.laptopInputOwned) private var laptopInputOwned
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
        if keyboardVisible && !model.windowCardOwnsGeometry && !laptopInputOwned, !view.isFirstResponder { DispatchQueue.main.async { view.becomeFirstResponder() } }
        if (!keyboardVisible || model.windowCardOwnsGeometry || laptopInputOwned), view.isFirstResponder { DispatchQueue.main.async { view.resignFirstResponder() } }
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
    /// A finger held on Launchpad is sliding through Quick Switch.
    private var switchHolding = false
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
            switchHolding = false
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
                // Held on Launchpad: Quick Switch, slid through with the same finger.
                if desktop.beginSwitchHold(session: self.session) {
                    self.switchHolding = true
                    return
                }
                desktop.click(button: 3, session: self.session, open: self.open)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } else { cancelHold() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = live(event)
        if switchHolding, let finger = fingers.first {
            desktop?.trackSwitchHold(at: finger.location(in: self))
            return
        }
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
        if switchHolding {
            switchHolding = false
            desktop.endSwitchHold()
            return
        }
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
        if switchHolding {
            switchHolding = false
            desktop?.cancelSwitchHold()
        }
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
