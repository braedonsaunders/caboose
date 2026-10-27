import CabooseKit
import SwiftUI
import UIKit

/// The phone as a Mac trackpad for the desktop on the big screen.
///
/// One finger moves the cursor with acceleration, tap clicks, two-finger tap right-clicks,
/// two fingers scroll, and tap-and-a-half (tap, then touch down again and move) drags.
struct TrackpadScreen: View {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("Desktop on your display", systemImage: "tv")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { model.keyboardVisible.toggle() } label: {
                    Image(systemName: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                        .frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
            Trackpad(desktop: desktop, keyboardVisible: model.keyboardVisible)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12)))
            Text("Tap to click · two fingers to scroll · tap with two to right-click · tap then drag to move")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }
}

struct Trackpad: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel
    let keyboardVisible: Bool

    func makeUIView(context: Context) -> TrackpadSurface {
        let view = TrackpadSurface()
        view.desktop = desktop
        view.model = model
        return view
    }

    func updateUIView(_ view: TrackpadSurface, context: Context) {
        view.desktop = desktop
        view.model = model
        if keyboardVisible, !view.isFirstResponder { DispatchQueue.main.async { view.becomeFirstResponder() } }
        if !keyboardVisible, view.isFirstResponder { DispatchQueue.main.async { view.resignFirstResponder() } }
    }
}

/// Raw multi-touch tracking; gesture recognizers add too much latency for a cursor.
final class TrackpadSurface: UIView, UIKeyInput {
    weak var desktop: DesktopModel?
    weak var model: AppModel?

    private var touchStart: TimeInterval = 0
    private var maxTouches = 0
    private var travel: CGFloat = 0
    private var lastCentroid: CGPoint?
    private var lastTapEnded: TimeInterval = 0
    private var dragging = false
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(white: 1, alpha: 0.05)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var session: XpraSession? { model?.session }

    private func centroid(_ event: UIEvent?) -> CGPoint? {
        guard let touches = event?.touches(for: self)?.filter({ $0.phase != .ended && $0.phase != .cancelled }), !touches.isEmpty
        else { return nil }
        let points = touches.map { $0.location(in: self) }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.touches(for: self)?.count ?? touches.count
        if maxTouches == 0 {
            touchStart = event?.timestamp ?? 0
            travel = 0
            // Tap-and-a-half: a touch that lands just after a tap starts a drag.
            if active == 1, (event?.timestamp ?? 0) - lastTapEnded < 0.3 {
                dragging = true
                desktop?.beginDrag(session: session)
                haptics.impactOccurred()
            }
        }
        maxTouches = max(maxTouches, active)
        lastCentroid = centroid(event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = centroid(event), let last = lastCentroid else { return }
        let delta = CGPoint(x: point.x - last.x, y: point.y - last.y)
        lastCentroid = point
        travel += hypot(delta.x, delta.y)
        let fingers = event?.touches(for: self)?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 1
        if fingers >= 2 && !dragging {
            desktop?.scroll(by: CGPoint(x: -delta.x * 2, y: -delta.y * 2), session: session)
        } else {
            // Acceleration: slow moves are precise, fast flicks cross the screen.
            let speed = hypot(delta.x, delta.y)
            let gain = 1.4 + min(speed * 0.12, 2.6)
            desktop?.move(by: CGPoint(x: delta.x * gain, y: delta.y * gain), session: session)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = event?.touches(for: self)?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
        lastCentroid = centroid(event)
        guard remaining == 0 else { return }
        let duration = (event?.timestamp ?? 0) - touchStart
        if dragging {
            desktop?.endDrag(session: session)
            dragging = false
        } else if duration < 0.25, travel < 10 {
            let open: (String) -> Void = { [weak self] id in
                guard let app = self?.model?.apps.first(where: { $0.id == id }) else { return }
                self?.model?.open(app)
            }
            desktop?.click(button: maxTouches >= 2 ? 3 : 1, session: session, open: open)
            haptics.impactOccurred()
            lastTapEnded = event?.timestamp ?? 0
        }
        maxTouches = 0
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if dragging { desktop?.endDrag(session: session) }
        dragging = false
        maxTouches = 0
        lastCentroid = nil
    }

    // MARK: Keyboard: typed text goes to the focused Linux window.

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
