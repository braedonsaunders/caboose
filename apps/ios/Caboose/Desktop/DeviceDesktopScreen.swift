import CabooseKit
import SwiftUI
import UIKit

/// The Desktop tab: the computer's whole desktop on this screen, windows side by side with
/// the dock and Launchpad; or, while a TV shows the desktop, this phone as its trackpad.
///
/// Its actions sit in the toolbar, so on iPhone Duo they join the tab bar in the vertical bar
/// on the side, which stays fully shown as on every tab. The desktop fills everything beside
/// the vertical bar, or between horizontal bars, and the computer lays its windows out for
/// exactly that space; when the bars change, so does the desktop. Full Screen gives it the
/// whole display until the handle at the top brings the bars back. Behind it all, under the
/// bar as well, is the desktop's photograph with a sheer of the brand gradient.
struct DesktopScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showAirPlay = false
    @State private var fullScreen = false

    var body: some View {
        NavigationStack {
            Group {
                if model.phase != .ready {
                    ComputerStateView()
                } else if model.externalDisplayActive {
                    TrackpadScreen(desktop: model.desktop)
                } else {
                    DesktopStage(fullScreen: fullScreen)
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
            .toolbarVisibility(fullScreen ? .hidden : .automatic, for: .navigationBar, .tabBar)
            .statusBarHidden(fullScreen)
            .persistentSystemOverlays(fullScreen ? .hidden : .automatic)
            .overlay(alignment: .top) { if fullScreen { exitFullScreenHandle } }
            .animation(.snappy, value: fullScreen)
            .onChange(of: model.phase) { _, phase in if phase != .ready { fullScreen = false } }
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
            Button(model.keyboardVisible ? "Hide Keyboard" : "Keyboard",
                   systemImage: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") {
                model.keyboardVisible.toggle()
            }
            Button("AirPlay", systemImage: model.airPlay.current != nil ? "airplay.audio" : "airplay.video") { showAirPlay = true }
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
            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { fullScreen = true }
        }
    }

    /// In full screen, a pull-down tab at the top edge brings the bars back.
    private var exitFullScreenHandle: some View {
        Capsule()
            .fill(.white.opacity(0.45))
            .frame(width: 44, height: 5)
            .padding(.top, 6)
            .frame(width: 120, height: 28, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { fullScreen = false }
            .gesture(DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height > 12 { fullScreen = false }
            })
            .accessibilityLabel("Exit Full Screen")
            .accessibilityAddTraits(.isButton)
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
            ZStack {
                DesktopView(desktop: model.desktop, fillsScreen: false)
                DesktopTouchArea(desktop: model.desktop, keyboardVisible: model.keyboardVisible)
            }
            .onAppear { model.desktopStageResized(to: proxy.size) }
            .onChange(of: proxy.size) { _, size in model.desktopStageResized(to: size) }
        }
        .ignoresSafeArea(edges: ignoredEdges)
    }

    private var ignoredEdges: Edge.Set {
        if fullScreen { return .all }
        switch barEdge {
        case .trailing: return [.top, .bottom, .leading]
        case .leading: return [.top, .bottom, .trailing]
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
        if keyboardVisible, !view.isFirstResponder { DispatchQueue.main.async { view.becomeFirstResponder() } }
        if !keyboardVisible, view.isFirstResponder { DispatchQueue.main.async { view.resignFirstResponder() } }
    }
}

final class DesktopTouchSurface: UIView, UIKeyInput {
    weak var desktop: DesktopModel?
    weak var model: AppModel?

    private var began: TimeInterval = 0
    private var travel: CGFloat = 0
    private var maxFingers = 0
    private var dragging = false
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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = live(event)
        if maxFingers == 0 {
            began = event?.timestamp ?? 0
            travel = 0
            dragging = false
            if let first = touches.first, touches.first?.type != .indirectPointer { desktop?.pointerHovering = false; point(at: first.location(in: self)) }
            else if let first = touches.first { point(at: first.location(in: self)) }
        }
        maxFingers = max(maxFingers, fingers.count)
        lastCentroid = centroid(fingers)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let fingers = live(event)
        guard let desktop, let now = centroid(fingers), let last = lastCentroid else { return }
        let delta = CGPoint(x: now.x - last.x, y: now.y - last.y)
        lastCentroid = now
        travel += hypot(delta.x, delta.y)
        if maxFingers >= 2 {
            // Content follows the fingers, like any iOS scroll view.
            desktop.scroll(by: CGPoint(x: -delta.x, y: -delta.y), session: session)
            return
        }
        if !dragging, travel > 8 {
            dragging = true
            desktop.beginDrag(session: session)
        }
        if dragging, let finger = fingers.first { point(at: finger.location(in: self)) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard live(event).isEmpty, let desktop else { return }
        let now = event?.timestamp ?? 0
        let duration = now - began
        defer { maxFingers = 0; lastCentroid = nil }
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
        if duration > 0.5 {
            desktop.click(button: 3, session: session, open: open)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        if let lastTap, now - lastTap.time < 0.35, hypot(desktop.cursor.x - lastTap.point.x, desktop.cursor.y - lastTap.point.y) < 24 {
            desktop.doubleClick(session: session, open: open)
            self.lastTap = nil
        } else {
            desktop.click(session: session, open: open)
            lastTap = (now, desktop.cursor)
        }
        haptics.impactOccurred()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if dragging { desktop?.endDrag(session: session) }
        dragging = false
        maxFingers = 0
        lastCentroid = nil
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none

    private var focusedWindow: RemoteWindow? {
        guard let session, let desktop else { return nil }
        return desktop.stacking.reversed().compactMap { session.windows[$0] }.first { !$0.isAuxiliary && desktop.isVisible($0.id) }
    }

    func insertText(_ text: String) { session?.type(text, in: focusedWindow) }

    func deleteBackward() {
        guard let stroke = Keysyms.special["BackSpace"] else { return }
        session?.key(stroke, pressed: true, in: focusedWindow)
        session?.key(stroke, pressed: false, in: focusedWindow)
    }
}
