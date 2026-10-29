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
                            DesktopStage()
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
            .shellRailActions {
                LaptopModeMenu()
                Button("Keyboard", systemImage: "keyboard") { model.keyboardVisible.toggle() }
                Button("AirPlay", systemImage: "airplay.video") { showAirPlay = true }
                if !model.externalDisplayActive, UIDevice.current.userInterfaceIdiom == .pad {
                    @Bindable var model = model
                    Picker("Arrangement", selection: $model.deviceDesktopStyle) {
                        Label("Tiled", systemImage: "rectangle.split.3x1").tag(AppModel.DeviceDesktopStyle.tiled)
                        Label("Free", systemImage: "macwindow.on.rectangle").tag(AppModel.DeviceDesktopStyle.free)
                    }
                }
                Button("Wallpaper", systemImage: "photo.on.rectangle") { model.wallpaperPickerPresented = true }
            }
            .keepsTabBarInVerticalBar()
            .toolbarVisibility(laptopActive || portraitDesktop || tabPlacement == .sidebar ? .hidden : .visible, for: .navigationBar)
            // A child automatic preference must not restore the system bar beneath
            // the shell's custom tabs after rotation.
            .toolbarVisibility(laptopActive || portraitDesktop || tabPlacement != .system ? .hidden : .visible, for: .tabBar)
            .statusBarHidden(laptopActive || portraitDesktop || tabPlacement == .sidebar)
            .persistentSystemOverlays(laptopActive ? .hidden : .automatic)
            .animation(.snappy, value: laptopActive)
            .sheet(isPresented: $showAirPlay) {
                AirPlaySheet().environment(model)
                    .presentationDetents([.medium])
            }
        }
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
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Desktop controls and navigation")
        .accessibilityHint("Opens desktop controls and app navigation")
        .popover(isPresented: $presented, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            ScrollView { panel }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 72, height: 512)
                // Even a narrow phone keeps the panel anchored and dismissible, rather
                // than adapting it into a full-screen presentation.
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: model.selectedTab) { _, _ in presented = false }
        .onDisappear { presented = false }
    }

    private var panel: some View {
        VStack(spacing: 4) {
            DesktopRailControls()
            Divider().frame(width: 32).padding(.vertical, 4)
            ShellTabButtons(axis: .vertical, iconsOnly: true)
            Button("Close desktop controls", systemImage: "chevron.down") { presented = false }
                .labelStyle(.iconOnly)
                .frame(width: 56, height: 44)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .frame(width: 72)
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
    @Environment(\.portraitDesktopChrome) private var portraitDesktop

    var body: some View {
        GeometryReader { proxy in
            Group {
                if model.deviceDesktopStyle == .tiled {
                    SwitchyardView(yard: model.yard)
                } else {
                    ZStack {
                        DesktopView(desktop: model.desktop, fillsScreen: false, showsDock: !portraitDesktop)
                        DesktopTouchArea(desktop: model.desktop, keyboardVisible: model.keyboardVisible)
                            .allowsHitTesting(!model.desktop.launchpadOpen)
                        DesktopKeyCommands(desktop: model.desktop)
                        if portraitDesktop, !model.desktop.detachedChrome,
                           let session = model.session, model.desktop.fullscreenWindow(in: session.windows) == nil {
                            Dock(desktop: model.desktop, interactive: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                .padding(.bottom, model.desktop.dockBottomInset)
                        }
                    }
                    .coordinateSpace(name: "desktop")
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

/// Touch straight on the desktop: a tap clicks, a finger pans app content, and holding
/// content before moving drags it. Title bars and corners drag immediately. Two fingers
/// also scroll; a two-finger tap opens context. Two taps double-click.
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

    private let scrollDriver = ScrollDriver()
    private var scrolling = false
    private var scrollSuppressed = false
    private var partialLift = false
    private var scrollOrigin = CGPoint.zero
    private var scrollOriginTime: TimeInterval = 0

    private var began: TimeInterval = 0
    private var travel: CGFloat = 0
    private var touchOrigin = CGPoint.zero
    private var maxFingers = 0
    private var dragging = false
    private var contextOpened = false
    /// Captured on contact, so a pan/hold cannot change its target before recognition.
    private var pansContent = false
    private weak var panWindow: RemoteWindow?
    private weak var panSession: (any DisplaySession)?
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
        NotificationCenter.default.addObserver(self, selector: #selector(cancelInteraction),
            name: UIApplication.willResignActiveNotification, object: nil)
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
        if window == nil { cancelInteraction() }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        scrollDriver.cancel()
        let fingers = live(event)
        if maxFingers > 0, (dragging || scrolling) {
            if dragging { releaseDrag() }
            dragging = false
            scrolling = false
            scrollSuppressed = true
            cancelHold()
            maxFingers = max(maxFingers, fingers.count)
            lastCentroid = centroid(fingers)
            return
        }
        scrolling = false
        if maxFingers == 0 {
            scrollSuppressed = false
            partialLift = false
            began = event?.timestamp ?? 0
            travel = 0
            dragging = false
            contextOpened = false
            switchHolding = false
            pansContent = false
            panWindow = nil
            panSession = nil
            cancelHold()
            if let first = touches.first, touches.first?.type != .indirectPointer { desktop?.pointerHovering = false; point(at: first.location(in: self)) }
            else if let first = touches.first { point(at: first.location(in: self)) }
        }
        maxFingers = max(maxFingers, fingers.count)
        lastCentroid = centroid(fingers)
        if let center = lastCentroid {
            scrollOrigin = center
            scrollOriginTime = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        }
        if maxFingers == 1, let point = lastCentroid { touchOrigin = point }
        if maxFingers == 1, let first = touches.first, first.type == .direct {
            if let desktop, let session,
               case .content(let id, _) = desktop.hitTest(touchOrigin, windows: session.windows) {
                pansContent = true
                panWindow = session.windows[id]
                panSession = session
            }
            press.begin(at: first.location(in: self), time: ProcessInfo.processInfo.systemUptime)
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let desktop = self.desktop, !self.dragging,
                          let point = self.press.context(at: ProcessInfo.processInfo.systemUptime) else { return }
                    self.scrollDriver.cancel()
                    self.lastTap = nil
                    self.point(at: point)
                    if self.pansContent {
                        guard let target = self.panWindow, let session = self.session, session === self.panSession,
                              session.state == .ready, session.windows[target.id] === target,
                              case .content(let id, _) = desktop.hitTest(point, windows: session.windows),
                              id == target.id else { self.scrollSuppressed = true; return }
                        self.dragging = true
                        desktop.beginDrag(session: session)
                        self.haptics.impactOccurred()
                        return
                    }
                    self.contextOpened = true
                    // Held on Launchpad: Quick Switch, slid through with the same finger.
                    if desktop.beginSwitchHold(session: self.session) {
                        self.switchHolding = true
                        return
                    }
                    desktop.click(button: 3, session: self.session, open: self.open)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        } else { cancelHold() }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = live(event)
        if switchHolding, let finger = fingers.first {
            desktop?.trackSwitchHold(at: finger.location(in: self))
            return
        }
        if partialLift {
            // A leftover finger cannot scroll, but movement still disqualifies a tap.
            if let now = centroid(fingers) {
                travel = max(travel, hypot(now.x - touchOrigin.x, now.y - touchOrigin.y))
            }
            return
        }
        guard !contextOpened, !scrollSuppressed else { return }
        if pansContent {
            guard let target = panWindow, let session, session === panSession,
                  session.state == .ready, session.windows[target.id] === target,
                  desktop?.isVisible(target.id) == true else {
                if dragging { releaseDrag() }
                dragging = false
                scrollDriver.cancel()
                scrollSuppressed = true
                cancelHold()
                return
            }
        }
        guard let desktop, let now = centroid(fingers), let last = lastCentroid else { return }
        let delta = CGPoint(x: now.x - last.x, y: now.y - last.y)
        lastCentroid = now
        travel = max(travel, hypot(now.x - touchOrigin.x, now.y - touchOrigin.y))
        press.move(to: now)
        if maxFingers >= 2 || (pansContent && !dragging) {
            // Capture the original target so inertia cannot cross windows or chrome.
            let time = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
            var scrollDelta = delta
            if !scrolling {
                scrollDelta = CGPoint(x: now.x - scrollOrigin.x, y: now.y - scrollOrigin.y)
                guard hypot(scrollDelta.x, scrollDelta.y) >= 4 else { return }
                guard let session, case .content(let id, let anchor) = desktop.hitTest(desktop.cursor, windows: session.windows),
                      let target = session.windows[id] else { return }
                if pansContent && (session !== panSession || target !== panWindow) {
                    scrollSuppressed = true
                    cancelHold()
                    return
                }
                cancelHold()
                lastTap = nil
                scrolling = true
                session.resetScroll()
                guard let mapping = desktop.inputMapping(for: target, windows: session.windows) else { return }
                let epoch = session.epoch
                let connection = (session as? CabooseDisplaySession)?.connections
                scrollDriver.begin(at: scrollOriginTime) { [weak self, weak session, weak target, weak desktop] delta in
                    guard let self, let session, let target, let desktop, self.window != nil,
                          self.session === session, self.desktop === desktop, session.state == .ready,
                          session.windows[id] === target, desktop.isVisible(id),
                          session.epoch == epoch, (session as? CabooseDisplaySession)?.connections == connection,
                          desktop.inputMapping(for: target, windows: session.windows) == mapping,
                          case .content(let current, _) = desktop.hitTest(desktop.cursor, windows: session.windows), current == id else { return false }
                    guard let remoteDelta = mapping.delta(delta) else { return false }
                    session.scroll(in: target, dx: remoteDelta.x, dy: remoteDelta.y, at: anchor)
                    return true
                }
            }
            scrollDriver.append(CGPoint(x: -scrollDelta.x, y: -scrollDelta.y), at: time)
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
        if scrolling {
            scrollDriver.end(at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime,
                             remainingContacts: live(event).count)
            scrolling = false
            scrollSuppressed = true
        }
        guard live(event).isEmpty, let desktop else {
            // Do not begin scrolling with the remaining contact. Preserve the
            // final two-finger tap: fingers normally lift at different times.
            partialLift = true
            cancelHold()
            lastCentroid = centroid(live(event))
            return
        }
        let now = event?.timestamp ?? 0
        let duration = now - began
        defer { maxFingers = 0; lastCentroid = nil; pansContent = false; panWindow = nil; panSession = nil; cancelHold() }
        if switchHolding {
            switchHolding = false
            desktop.endSwitchHold()
            return
        }
        if contextOpened || scrollSuppressed { return }
        if dragging {
            releaseDrag()
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
        cancelInteraction()
    }

    private func releaseDrag() {
        if pansContent {
            let liveTarget = panWindow.map { panSession?.windows[$0.id] === $0 } ?? false
            desktop?.endDrag(session: liveTarget ? panSession : nil)
        } else {
            desktop?.endDrag(session: session)
        }
    }

    @objc private func cancelInteraction() {
        scrollDriver.cancel()
        scrolling = false
        scrollSuppressed = true
        cancelHold()
        if switchHolding {
            switchHolding = false
            desktop?.cancelSwitchHold()
        }
        if dragging { releaseDrag() }
        dragging = false
        maxFingers = 0
        lastCentroid = nil
        pansContent = false
        panWindow = nil
        panSession = nil
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
