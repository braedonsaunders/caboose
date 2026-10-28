import CabooseKit
import SwiftUI
import UIKit

/// The Mac-like desktop on this phone's or iPad's own screen. Home stays the launcher; this
/// is the computer's whole desktop when you want windows side by side.
struct DeviceDesktopScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                DesktopView(desktop: model.desktop)
                DesktopTouchArea(desktop: model.desktop, keyboardVisible: model.keyboardVisible)
                    .ignoresSafeArea()
                controls
                    .padding(.top, max(8, proxy.safeAreaInsets.top))
                    .padding(.trailing, max(10, proxy.safeAreaInsets.trailing))
            }
            .onChange(of: proxy.size) { _, _ in model.deviceDesktopResized(to: fullSize(proxy)) }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private func fullSize(_ proxy: GeometryProxy) -> CGSize {
        CGSize(width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
               height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { model.keyboardVisible.toggle() } label: {
                Image(systemName: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    .frame(width: 36, height: 36)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(model.keyboardVisible ? "Hide keyboard" : "Show keyboard")
            Button { withAnimation(.smooth) { model.closeDeviceDesktop() } } label: {
                Image(systemName: "square.grid.2x2").frame(width: 36, height: 36)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Back to Home")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
    }
}

/// Home's way in: a desktop, so it looks like one, apart from the app grid.
struct DesktopCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            let bounds = UIScreen.main.bounds
            withAnimation(.smooth) { model.openDeviceDesktop(size: bounds.size) }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.6), Color(red: 0.55, green: 0.3, blue: 0.45)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    // Two little windows and a dock: the desktop at a glance.
                    VStack(spacing: 3) {
                        HStack(alignment: .top, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.85)).frame(width: 26, height: 18)
                            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.6)).frame(width: 18, height: 24)
                        }
                        Capsule().fill(.white.opacity(0.45)).frame(width: 34, height: 5)
                    }
                }
                .frame(width: 64, height: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Desktop").font(.headline)
                    Text("Your windows side by side, with the dock and Launchpad")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
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

    private var session: XpraSession? { model?.session }

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
