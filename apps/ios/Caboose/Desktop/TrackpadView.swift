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
                Button { model.adjustDesktopZoom(by: 1 / 1.15) } label: {
                    Image(systemName: "textformat.size.smaller").frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Smaller")
                Button { model.adjustDesktopZoom(by: 1.15) } label: {
                    Image(systemName: "textformat.size.larger").frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Larger")
                Button { WallpaperStore.shared.next() } label: {
                    Image(systemName: "photo.on.rectangle.angled").frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("New wallpaper")
                Button { model.keyboardVisible.toggle() } label: {
                    Image(systemName: model.keyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                        .frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
            Trackpad(desktop: desktop, keyboardVisible: model.keyboardVisible)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12)))
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                Text(model.connectionSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
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

    private var gestures = TrackpadGestures()
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

    private func liveTouches(_ event: UIEvent?) -> Int {
        event?.touches(for: self)?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        perform(gestures.began(touches: max(1, liveTouches(event)), centroid: centroid(event), at: event?.timestamp ?? 0))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = centroid(event) else { return }
        perform(gestures.moved(touches: liveTouches(event), centroid: point, at: event?.timestamp ?? 0))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        perform(gestures.ended(remaining: liveTouches(event), centroid: centroid(event), at: event?.timestamp ?? 0))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        perform(gestures.cancelled())
    }

    private func perform(_ actions: [TrackpadGestures.Action]) {
        let open: (String) -> Void = { [weak self] id in
            guard let app = self?.model?.apps.first(where: { $0.id == id }) else { return }
            self?.model?.openOnDesktop(app)
        }
        for action in actions {
            switch action {
            case .move(let delta): desktop?.move(by: delta, session: session)
            case .scroll(let delta): desktop?.scroll(by: delta, session: session)
            case .beginDrag:
                desktop?.beginDrag(session: session)
                haptics.impactOccurred()
            case .endDrag: desktop?.endDrag(session: session)
            case .click(let button):
                desktop?.click(button: button, session: session, open: open)
                haptics.impactOccurred()
            case .doubleClick:
                // The second press and release reach the app; the desktop then handles its own double-click (title bar zoom).
                desktop?.beginDrag(session: session)
                desktop?.endDrag(session: session)
                desktop?.doubleClick(session: session, open: open)
            }
        }
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
