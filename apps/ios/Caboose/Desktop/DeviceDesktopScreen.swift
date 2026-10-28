import CabooseKit
import SwiftUI
import UIKit

/// The Desktop tab: the computer's whole desktop on this screen, windows side by side with
/// the dock and Launchpad; or, while a TV shows the desktop, this phone as its trackpad.
///
/// Its actions sit in the toolbar, so on iPhone Duo they join the tab bar in the vertical bar
/// on the side, and the tab bar gives way to them first when space runs short. The desktop
/// itself fills the safe area: the computer lays its windows out for exactly the space left
/// beside the vertical bar, or between the top and bottom bars.
struct DesktopScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showAgents = false
    @State private var showAirPlay = false

    var body: some View {
        NavigationStack {
            Group {
                if model.phase != .ready {
                    ComputerStateView().background { Backdrop() }
                } else if model.externalDisplayActive {
                    TrackpadScreen(desktop: model.desktop).background { Backdrop() }
                } else {
                    DesktopStage()
                }
            }
            .navigationTitle("Desktop")
            .navigationBarTitleDisplayMode(.inline)
            // The desktop needs the height more than a title: with the vertical bar the top
            // edge then belongs to the desktop alone.
            .toolbar(removing: .title)
            .toolbar {
                if model.phase == .ready { actions }
                ComputerToolbar()
            }
            .prefersToolbarItemsInVerticalBar()
            .sheet(isPresented: $showAgents) {
                AgentsScreen(dismiss: { showAgents = false }).environment(model)
            }
            .sheet(isPresented: $showAirPlay) {
                AirPlaySheet().environment(model)
                    .presentationDetents([.medium])
            }
        }
    }

    @ToolbarContentBuilder private var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(model.keyboardVisible ? "Hide Keyboard" : "Keyboard",
                   systemImage: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard") {
                model.keyboardVisible.toggle()
            }
            if !model.externalDisplayActive {
                Button("Apps", systemImage: "square.grid.3x3") {
                    withAnimation(.snappy) { model.desktop.launchpadOpen.toggle() }
                }
            }
            Button("Agents", systemImage: "sparkles") { showAgents = true }
                .badge(model.agents.awaitingApproval.count)
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            Button("AirPlay", systemImage: model.airPlay.current != nil ? "airplay.audio" : "airplay.video") { showAirPlay = true }
        }
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
    }
}

/// The phone's own desktop in the space the tab gives it.
private struct DesktopStage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                DesktopView(desktop: model.desktop, fillsScreen: false)
                DesktopTouchArea(desktop: model.desktop, keyboardVisible: model.keyboardVisible)
            }
            .onAppear { model.desktopStageResized(to: proxy.size) }
            .onChange(of: proxy.size) { _, size in model.desktopStageResized(to: size) }
        }
        .background(Color.black.ignoresSafeArea())
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
