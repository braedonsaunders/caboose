import CabooseKit
import SwiftUI
import UIKit

/// One window's tile: the live Linux window, cut to a small continuous corner with a fine
/// bevel and the grabber that moves it. Focus brightens the grabber without outlining the app.
struct YardTile: View {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let yard: YardModel
    let rect: CGRect
    let focused: Bool
    let keyboard: Bool
    let onAsk: (RemoteWindow) -> Void

    var body: some View {
        let radius = yard.metrics.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .top) {
            YardSurface(window: window, pixelsPerPoint: yard.pixelsPerPoint, stretch: yard.stretches(window.id), keyboard: keyboard) {
                if yard.layout.focused != window.id { yard.focus(window.id) }
            }
            .modifier(WindowDrop(window: window, pixelsPerPoint: yard.pixelsPerPoint))
            // Tiles without the keyboard step back a little; their text stays sharp.
            Color.black.opacity(focused ? 0 : 0.1).allowsHitTesting(false)
            YardGrabber(window: window, yard: yard, focused: focused, onAsk: onAsk)
        }
        .frame(width: rect.width, height: rect.height)
        .background(Color(white: 0.06))
        .clipShape(shape)
        // The bevel: light along the top edge, a little shade along the bottom, as glass has.
        .overlay {
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.07), .black.opacity(0.28)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(window.title.isEmpty ? "Window" : window.title)
    }
}

enum YardStyle {
    static let navy = Color(red: 0.07, green: 0.12, blue: 0.24)
    /// The focus ring: amber running into a cool blue and back, like light round a rim.
    static let ring = AngularGradient(colors: [Brand.amber, Color(red: 1, green: 0.84, blue: 0.48), Color(red: 0.36, green: 0.55, blue: 1),
                                               Brand.amber.opacity(0.85), Brand.amber],
                                      center: .center, angle: .degrees(-90))
}

/// The handle at the top of each tile: tap twice for full screen, hold for the tile's menu,
/// drag to carry the tile to another place on the track.
struct YardGrabber: View {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let yard: YardModel
    let focused: Bool
    let onAsk: (RemoteWindow) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(focused ? 0.9 : 0.55))
                .frame(width: 30, height: 4)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
                .frame(width: 84, height: 28)
                .contentShape(Rectangle())
                .gesture(
                    TapGesture(count: 2).onEnded { openCard() }
                        .exclusively(before: TapGesture().onEnded { yard.focus(window.id) })
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .named(SwitchyardView.space))
                        .onChanged { value in yard.carry(window.id, by: value.translation) }
                        .onEnded { _ in yard.drop() }
                )
                .contextMenu { menuContent }
                .accessibilityLabel("Move \(window.title.isEmpty ? "Window" : window.title)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { yard.focus(window.id) }
                .accessibilityAction(named: "Full Screen") { openCard() }

            Menu { menuContent } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(window.title.isEmpty ? "Window" : window.title) options")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(focused ? 0.9 : 0.65))
        .buttonStyle(.plain)
    }

    private func openCard() { model.show(windowID: window.id) }

    @ViewBuilder private var menuContent: some View {
        Section(window.title.isEmpty ? "Window" : window.title) {
            if yard.metrics.presets.count > 1, let index = yard.layout.columnIndex(of: window.id) {
                let current = yard.metrics.effectiveFraction(yard.layout.columns[index].width)
                Menu("Width", systemImage: "arrow.left.and.right") {
                    ForEach(yard.metrics.presets, id: \.self) { fraction in
                        Button { yard.setWidth(fraction, of: window.id) } label: {
                            if abs(fraction - current) < 0.01 {
                                Label(Self.name(fraction), systemImage: "checkmark")
                            } else {
                                Text(Self.name(fraction))
                            }
                        }
                    }
                }
            }
            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right", action: openCard)
            Button("Exit App Full Screen", systemImage: "arrow.down.right.and.arrow.up.left") {
                yard.exitAppFullscreen(window.id)
            }
            if model.agents.available {
                Button("Ask Agent About This Window", systemImage: "sparkle") { onAsk(window) }
            }
            Button("Redraw", systemImage: "arrow.clockwise") { model.session?.refresh(window) }
        }
        Button("Close Window", systemImage: "xmark", role: .destructive) { yard.close(window.id) }
    }

    static func name(_ fraction: CGFloat) -> String {
        switch fraction {
        case ..<0.4: "One Third"
        case ..<0.6: "Half"
        case ..<0.9: "Two Thirds"
        default: "Full Width"
        }
    }
}

/// The live window inside a tile. Linux draws it at the tile's size; until a new size
/// arrives, its last picture is stretched over the tile so a resize never shows a seam. A
/// window that keeps a size of its own is shown at it, centred.
struct YardSurface: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let pixelsPerPoint: CGFloat
    let stretch: Bool
    let keyboard: Bool
    let onTouch: () -> Void

    func makeUIView(context: Context) -> YardSurfaceView {
        let view = YardSurfaceView(content: RemoteWindowView(session: model.yardActive ? model.session : nil, window: window))
        view.content.pixelsPerPoint = pixelsPerPoint
        view.content.showsVideo = model.yardActive
        let model = model
        view.content.onKeyboardWanted = { wanted in
            if model.keyboardVisible != wanted { model.keyboardVisible = wanted }
        }
        return view
    }

    func updateUIView(_ view: YardSurfaceView, context: Context) {
        view.content.session = model.yardActive ? model.session : nil
        view.content.showsVideo = model.yardActive
        view.content.pixelsPerPoint = pixelsPerPoint
        if view.content.remoteWindow?.id != window.id { view.content.attach(window) }
        view.onTouch = onTouch
        view.stretch = stretch
        view.natural = CGSize(width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
        if keyboard && model.yardActive, !view.content.isFirstResponder {
            DispatchQueue.main.async { view.content.becomeFirstResponder() }
        } else if (!keyboard || !model.yardActive), view.content.isFirstResponder {
            DispatchQueue.main.async { view.content.resignFirstResponder() }
        }
    }
}

final class YardSurfaceView: UIView {
    let content: RemoteWindowView
    var onTouch: (() -> Void)?
    var stretch = false { didSet { if stretch != oldValue { setNeedsLayout() } } }
    var natural: CGSize = .zero { didSet { if natural != oldValue { setNeedsLayout() } } }

    init(content: RemoteWindowView) {
        self.content = content
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(content)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A finger landing anywhere in the window gives its tile the focus; the window still
    /// gets the touch.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit != nil, event?.type == .touches { onTouch?() }
        return hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = natural.width > 0 && natural.height > 0 ? natural : bounds.size
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: size)
        let shown = DesktopGeometry.surfaceFrame(natural: size, available: bounds.size, resizing: stretch)
        guard size.width > 0, size.height > 0 else { return }
        content.transform = CGAffineTransform(scaleX: shown.width / size.width, y: shown.height / size.height)
        content.center = CGPoint(x: shown.midX, y: shown.midY)
    }
}
