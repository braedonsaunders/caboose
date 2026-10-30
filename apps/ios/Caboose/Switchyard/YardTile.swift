import CabooseKit
import SwiftUI
import UIKit

/// One window's tile: a title bar with the window's controls and title, and below it the
/// live Linux window, together cut to a small continuous corner with a fine bevel. The bar
/// never covers the app: the window is laid out for the space below it. Focus brightens
/// the bar without outlining the app.
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
        VStack(spacing: 0) {
            YardTitleBar(window: window, yard: yard, focused: focused, onAsk: onAsk)
            ZStack {
                YardSurface(window: window, pixelsPerPoint: yard.pixelsPerPoint, stretch: yard.stretches(window.id), keyboard: keyboard) {
                    if yard.layout.focused != window.id { yard.focus(window.id) }
                }
                .modifier(WindowDrop(window: window, pixelsPerPoint: yard.pixelsPerPoint))
                // Tiles without the keyboard step back a little; their text stays sharp.
                Color.black.opacity(focused ? 0 : 0.1).allowsHitTesting(false)
            }
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

/// The bar at the top of each tile, above the window: Close and Full Screen at its leading
/// edge, the title, and the tile's menu. Tap the title to focus the tile, tap it twice for
/// full screen, hold it for the menu, and drag it to carry the tile to another place on the
/// track.
struct YardTitleBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let window: RemoteWindow
    let yard: YardModel
    let focused: Bool
    let onAsk: (RemoteWindow) -> Void

    private var title: String { window.title.isEmpty ? "Window" : window.title }

    var body: some View {
        let bar = yard.metrics.titleBar
        HStack(spacing: 0) {
            WindowControls(bar: bar, showsSymbols: true, title: title) { control in
                switch control {
                case .close: yard.close(window.id)
                case .zoom: openCard()
                case .minimize: break
                }
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .accessibilityLabel("Move \(title)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { yard.focus(window.id) }
                .accessibilityAction(named: "Full Screen") { openCard() }
            Menu { menuContent } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 40, height: bar.height)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("\(title) options")
        }
        .frame(height: bar.height)
        .foregroundStyle(.white.opacity(focused ? 0.92 : 0.6))
        .buttonStyle(.plain)
        .background(Color(white: focused ? 0.16 : 0.11))
        .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.45)).frame(height: 0.5) }
    }

    private func openCard() { model.show(windowID: window.id, borderless: true) }

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
            if let ref = model.windowRef(for: window) {
                Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(value: ref) }
            }
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
    @Environment(\.laptopInputOwned) private var laptopInputOwned
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
        view.locallyRendered = window.game != nil
        view.natural = CGSize(width: window.frame.width / pixelsPerPoint, height: window.frame.height / pixelsPerPoint)
        view.laptopPoint = laptopInputOwned ? LaptopPointer.shared.point(in: window, session: model.session) : nil
        if keyboard && model.yardActive && !laptopInputOwned, !view.content.isFirstResponder {
            DispatchQueue.main.async { view.content.becomeFirstResponder() }
        } else if (!keyboard || !model.yardActive || laptopInputOwned), view.content.isFirstResponder {
            DispatchQueue.main.async { view.content.resignFirstResponder() }
        }
    }
}

final class YardSurfaceView: UIView {
    let content: RemoteWindowView
    var onTouch: (() -> Void)?
    var stretch = false { didSet { if stretch != oldValue { setNeedsLayout() } } }
    var locallyRendered = false { didSet { if locallyRendered != oldValue { setNeedsLayout() } } }
    var natural: CGSize = .zero { didSet { if natural != oldValue { setNeedsLayout() } } }
    var laptopPoint: CGPoint? { didSet { if laptopPoint != oldValue { setNeedsLayout() } } }
    private let laptopCursor = UIImageView(image: UIImage(systemName: "cursorarrow"))

    init(content: RemoteWindowView) {
        self.content = content
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(content)
        laptopCursor.tintColor = .white
        laptopCursor.isUserInteractionEnabled = false
        laptopCursor.layer.shadowColor = UIColor.black.cgColor
        laptopCursor.layer.shadowOpacity = 0.9
        laptopCursor.layer.shadowRadius = 2
        laptopCursor.layer.shadowOffset = .zero
        content.addSubview(laptopCursor)
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
        let size = DesktopGeometry.surfaceSize(natural: natural, available: bounds.size, locallyRendered: locallyRendered)
        content.transform = .identity
        content.bounds = CGRect(origin: .zero, size: size)
        let shown = DesktopGeometry.surfaceFrame(natural: size, available: bounds.size, resizing: stretch)
        guard size.width > 0, size.height > 0 else { return }
        content.transform = CGAffineTransform(scaleX: shown.width / size.width, y: shown.height / size.height)
        content.center = CGPoint(x: shown.midX, y: shown.midY)
        laptopCursor.isHidden = laptopPoint == nil
        if let point = laptopPoint {
            let sx = max(0.01, shown.width / size.width), sy = max(0.01, shown.height / size.height)
            laptopCursor.frame = CGRect(x: point.x * size.width, y: point.y * size.height, width: 18 / sx, height: 24 / sy)
            content.bringSubviewToFront(laptopCursor)
        }
    }
}
