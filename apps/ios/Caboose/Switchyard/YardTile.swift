import CabooseKit
import SwiftUI
import UIKit

/// One window's tile: the live Linux window, cut to a small continuous corner with a fine
/// bevel, the focus ring when it has the keyboard, and the grabber that moves it.
struct YardTile: View {
    @Environment(AppModel.self) private var model
    let window: RemoteWindow
    let yard: YardModel
    let rect: CGRect
    let focused: Bool
    let keyboard: Bool
    let onAsk: (RemoteWindow) -> Void

    @State private var ringIn = false

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
        .overlay {
            shape.strokeBorder(YardStyle.ring, lineWidth: ringIn ? 1.75 : 5)
                .opacity(focused && ringIn ? 1 : 0)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
        .onChange(of: focused, initial: true) { _, now in
            if now { ringIn = false; withAnimation(.smooth(duration: 0.35)) { ringIn = true } }
        }
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
    @State private var lastTap = Date.distantPast

    var body: some View {
        Menu {
            menuContent
        } label: {
            Capsule()
                .fill(.white.opacity(focused ? 0.9 : 0.55))
                .frame(width: 30, height: 4)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
                .frame(width: 84, height: 20)
                .contentShape(Rectangle())
        } primaryAction: {
            // Two taps, as on a Mac's title bar, zoom; one gives the tile the keyboard.
            if Date().timeIntervalSince(lastTap) < 0.35 {
                lastTap = .distantPast
                yard.zoom(window.id)
            } else {
                lastTap = Date()
                yard.focus(window.id)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(SwitchyardView.space))
                .onChanged { value in yard.carry(window.id, by: value.translation) }
                .onEnded { _ in yard.drop() }
        )
        .accessibilityLabel("\(window.title.isEmpty ? "Window" : window.title) options")
        .accessibilityAction(named: "Full Screen") { yard.zoom(window.id) }
    }

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
            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { yard.zoom(window.id) }
            Button("Open as Card", systemImage: "rectangle.portrait.on.rectangle.portrait") {
                model.show(windowID: window.id)
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
        let view = YardSurfaceView(content: RemoteWindowView(session: model.session, window: window))
        view.content.pixelsPerPoint = pixelsPerPoint
        let model = model
        view.content.onKeyboardWanted = { wanted in
            if model.keyboardVisible != wanted { model.keyboardVisible = wanted }
        }
        return view
    }

    func updateUIView(_ view: YardSurfaceView, context: Context) {
        view.content.session = model.session
        view.content.pixelsPerPoint = pixelsPerPoint
        if view.content.remoteWindow?.id != window.id { view.content.attach(window) }
        view.onTouch = onTouch
        view.stretch = stretch
        view.natural = CGSize(width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
        if keyboard, !view.content.isFirstResponder {
            DispatchQueue.main.async { view.content.becomeFirstResponder() }
        } else if !keyboard, view.content.isFirstResponder {
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
        let wider = size.width > bounds.width + 1, taller = size.height > bounds.height + 1
        if stretch, abs(size.width - bounds.width) > 1 || abs(size.height - bounds.height) > 1 {
            // Fill the tile from its top-left corner, as the new layout will.
            let scale = max(bounds.width / size.width, bounds.height / size.height)
            place(scale: scale, size: size, centred: false)
        } else if wider || taller {
            // An app that will not go as small as its tile (a minimum width of its own) is
            // shown whole, a little smaller, rather than cut off at the tile's edge.
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            place(scale: scale, size: size, centred: true)
        } else {
            place(scale: 1, size: size, centred: true)
        }
    }

    /// Scales the window about its top-left corner and places it at the top of the tile,
    /// centred across it when it is narrower.
    private func place(scale: CGFloat, size: CGSize, centred: Bool) {
        if scale != 1 { content.transform = CGAffineTransform(scaleX: scale, y: scale) }
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        let x = centred ? max(0, (bounds.width - shown.width) / 2) : 0
        // Shrunk to fit, it keeps to the top like any tile; a small window sits in the middle.
        let y = centred && scale >= 1 ? max(0, (bounds.height - shown.height) / 2) : 0
        content.center = CGPoint(x: x + shown.width / 2, y: y + shown.height / 2)
    }
}
