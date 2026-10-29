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
    @State private var gestureHelp = false

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
                Button { model.toggleDesktopFull4K() } label: {
                    Text(model.desktopFull4K ? "4K" : "HD").font(.caption.weight(.bold)).frame(width: 40, height: 40)
                }
                .glassEffect(model.desktopFull4K ? .regular.tint(.blue).interactive() : .regular.interactive(), in: .circle)
                .accessibilityLabel(model.desktopFull4K ? "Render the desktop at 2560 by 1440" : "Render the desktop at full 4K")
                Button { WallpaperStore.shared.next() } label: {
                    Image(systemName: "photo.on.rectangle.angled").frame(width: 40, height: 40)
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("New wallpaper")
                if !model.keyboardVisible {
                    Button { model.keyboardVisible = true } label: {
                        Image(systemName: "keyboard").frame(width: 40, height: 40)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Keyboard")
                }
            }
            Trackpad(desktop: desktop, keyboardVisible: model.keyboardVisible,
                     enabled: model.presentedWindowID == nil && model.selectedTab == .desktop)
                .background { DesktopKeyCommands(desktop: desktop) }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12)))
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                Text(model.connectionSummary).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button("Trackpad gestures", systemImage: "hand.draw") { gestureHelp = true }
                .font(.caption)
                .sheet(isPresented: $gestureHelp) { TrackpadGestureGuide() }
        }
        .padding(16)
    }
}

struct Trackpad: UIViewRepresentable {
    @Environment(AppModel.self) private var model
    let desktop: DesktopModel?
    var target: RemoteWindow? = nil
    let keyboardVisible: Bool
    var enabled = true
    var pointerEnabled = true
    var sharedSurface: TrackpadSurface? = nil
    var inlineControls = false
    var dismissInline: (() -> Void)? = nil

    func makeUIView(context: Context) -> TrackpadSurface {
        let view = sharedSurface ?? TrackpadSurface()
        view.desktop = desktop
        view.model = model
        view.target = target
        view.inputEnabled = enabled
        view.pointerEnabled = pointerEnabled
        return view
    }

    func updateUIView(_ view: TrackpadSurface, context: Context) {
        view.desktop = desktop
        view.model = model
        view.target = target
        view.inlineKeyboardControls = inlineControls
        view.dismissInline = dismissInline
        view.wantsKeyboard = (keyboardVisible || inlineControls) && enabled
        if view.autocorrectChoice == nil {
            if let purpose = model.session?.textPurpose {
                view.prefersProse = !["terminal", "password", "pin", "url", "email", "number", "digits", "phone", "date", "time", "datetime"].contains(purpose)
            } else { view.prefersProse = !RemoteWindowView.isCodeApp(target) }
        }
        if (!enabled && view.inputEnabled) || (!pointerEnabled && view.pointerEnabled) { view.endInteraction() }
        view.inputEnabled = enabled
        view.pointerEnabled = pointerEnabled
        DispatchQueue.main.async { [weak view] in
            guard let view, view.window != nil else { return }
            if view.wantsKeyboard, !view.isFirstResponder { view.becomeFirstResponder() }
            if !view.wantsKeyboard, view.isFirstResponder { view.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ view: TrackpadSurface, coordinator: ()) { view.endInteraction() }
}

/// Raw multi-touch tracking; gesture recognizers add too much latency for a cursor.
final class TrackpadSurface: RemoteTextInputView {
    weak var desktop: DesktopModel?
    weak var model: AppModel?
    var dismissInline: (() -> Void)?
    var wantsKeyboard = false
    var inputEnabled = true
    var pointerEnabled = true
    weak var target: RemoteWindow? {
        willSet {
            if newValue !== target {
                endInteraction()
                point = CGPoint(x: 0.5, y: 0.5)
                resetTyping()
            }
        }
    }
    private var point = CGPoint(x: 0.5, y: 0.5)
    private var focusTask: Task<Void, Never>?

    private var gestures = TrackpadGestures()
    private var zoomGesture = TrackpadZoom()
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(white: 1, alpha: 0.05)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var session: (any DisplaySession)? { model?.session }

    private func centroid(_ event: UIEvent?) -> CGPoint? {
        guard let touches = event?.touches(for: self)?.filter({ $0.phase != .ended && $0.phase != .cancelled }), !touches.isEmpty
        else { return nil }
        let points = touches.map { $0.location(in: self) }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }

    private func liveTouches(_ event: UIEvent?) -> Int {
        event?.touches(for: self)?.filter { $0.phase != .ended && $0.phase != .cancelled }.count ?? 0
    }

    // Reserve multi-finger gestures for the remote workspace rather than iOS edit menus.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    private func spread(_ event: UIEvent?) -> CGFloat? {
        guard let center = centroid(event), let touches = event?.touches(for: self)?.filter({ $0.phase != .ended && $0.phase != .cancelled }), touches.count >= 2 else { return nil }
        return touches.map { touch in
            let p = touch.location(in: self)
            return hypot(p.x - center.x, p.y - center.y)
        }.reduce(0, +) / CGFloat(touches.count)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        perform(gestures.began(touches: max(1, liveTouches(event)), centroid: centroid(event), at: event?.timestamp ?? 0, spread: spread(event)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = centroid(event) else { return }
        perform(gestures.moved(touches: liveTouches(event), centroid: point, at: event?.timestamp ?? 0, spread: spread(event)))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        zoomGesture.reset()
        perform(gestures.ended(remaining: liveTouches(event), centroid: centroid(event), at: event?.timestamp ?? 0, spread: spread(event)))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        zoomGesture.reset()
        perform(gestures.cancelled())
    }

    private func perform(_ actions: [TrackpadGestures.Action]) {
        guard inputEnabled && pointerEnabled else { return }
        let open: (String) -> Void = { [weak self] id in
            guard let app = self?.model?.apps.first(where: { $0.id == id }) else { return }
            self?.model?.openOnDesktop(app)
        }
        for action in actions {
            switch action {
            case .workspace(let direction): performWorkspace(direction); continue
            case .zoom(let delta): performZoom(delta); continue
            default: break
            }
            if let target { perform(action, in: target); continue }
            switch action {
            case .workspace, .zoom: break // handled before window routing
            case .move(let delta):
                desktop?.pointerHovering = true
                desktop?.move(by: delta, session: session)
            case .scroll(let delta): desktop?.scroll(by: delta, session: session)
            case .beginDrag:
                desktop?.beginDrag(session: session)
                haptics.impactOccurred()
            case .endDrag: desktop?.endDrag(session: session)
            case .click(let button):
                resetTyping()
                defer { prefersProse = autocorrectChoice ?? !RemoteWindowView.isCodeApp(focusedWindow) }
                desktop?.click(button: button, session: session, open: open)
                if button == 1 { checkDesktopTextFocus() }
                haptics.impactOccurred()
            case .doubleClick:
                resetTyping()
                desktop?.doubleClick(session: session, open: open)
                checkDesktopTextFocus()
            }
        }
    }

    /// Laptop control uses the same trackpad gestures, aimed at the card/focused tile.
    /// Free desktops and external monitors continue through DesktopModel's hit testing.
    private func perform(_ action: TrackpadGestures.Action, in target: RemoteWindow) {
        guard let session, session.state == .ready, session.windows[target.id] === target else { return }
        func pixel() -> CGPoint { CGPoint(x: point.x * target.frame.width, y: point.y * target.frame.height) }
        func button(_ button: Int, _ down: Bool) {
            session.pointerButton(in: target, button: button, pressed: down, at: pixel())
        }
        switch action {
        case .workspace, .zoom: break // handled before window routing
        case .move(let delta):
            let scale = model?.pixelsPerPoint ?? 1
            point.x = min(0.999, max(0, point.x + delta.x * scale / max(1, target.frame.width)))
            point.y = min(0.999, max(0, point.y + delta.y * scale / max(1, target.frame.height)))
            session.pointerMove(in: target, to: pixel())
        case .scroll(let delta): session.scroll(in: target, dx: delta.x, dy: delta.y, at: pixel())
        case .beginDrag: session.focus(target); button(1, true)
        case .endDrag: button(1, false)
        case .click(let number):
            session.focus(target)
            button(number, true); button(number, false)
            if number == 1 { checkTextFocus(session, target: target) }
            haptics.impactOccurred()
        case .doubleClick:
            session.focus(target)
            button(1, true); button(1, false)
            checkTextFocus(session, target: target)
        }
        LaptopPointer.shared.show(in: target, session: session, at: point, owner: self)
    }

    private func performZoom(_ delta: CGFloat) {
        guard let session, session.state == .ready, let window = focusedWindow else { return }
        let steps = zoomGesture.consume(delta)
        guard steps != 0, let stroke = Keysyms.stroke(for: steps > 0 ? "+" : "-") else { return }
        // Use the app's standard zoom shortcut: no ignored pointer modifier field,
        // held Control key, or app-specific DOM/browser behavior.
        for _ in 0..<abs(steps) {
            session.key(stroke, pressed: true, in: window, extraModifiers: ["control"])
            session.key(stroke, pressed: false, in: window, extraModifiers: ["control"])
        }
    }

    private func performWorkspace(_ direction: TrackpadGestures.Direction) {
        guard let model, let session, session.state == .ready else { return }
        switch direction {
        case .up:
            if model.presentedWindowID != nil { model.presentedWindowID = nil; return }
            let workspace = desktop ?? model.desktop
            model.quickSwitch.present(recent: model.recentWindowIDs, desktop: workspace.switchTarget(session: session))
        case .down:
            model.quickSwitch.cancel()
            (desktop ?? model.desktop).launchpadOpen = false
        case .left, .right:
            let windows = model.appWindows.sorted { $0.id < $1.id }
            guard !windows.isEmpty else { return }
            let current = focusedWindow?.id
            let index = windows.firstIndex { $0.id == current } ?? 0
            let step = direction == .left ? 1 : -1
            let next = windows[(index + step + windows.count) % windows.count]
            model.quickSwitch.cancel()
            if model.presentedWindowID != nil { model.presentedWindowID = next.id }
            else { (desktop ?? model.desktop).activate(next.id, session: session) }
        }
        haptics.impactOccurred()
    }

    private func checkDesktopTextFocus() {
        guard let desktop, let session,
              case .content(let id, _) = desktop.hitTest(desktop.cursor, windows: session.windows),
              let window = session.windows[id], !window.isOverrideRedirect else { return }
        checkTextFocus(session, target: window)
    }

    private func checkTextFocus(_ session: any DisplaySession, target: RemoteWindow) {
        focusTask?.cancel()
        let check = TapTextFocus(since: CACurrentMediaTime(), serial: session.cursorSerial)
        focusTask = Task { [weak self, weak target, weak session] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self, let target, let session,
                      self.inputEnabled, self.focusedWindow === target, self.session === session, self.window != nil else { return }
                if let wanted = check.keyboardWanted(at: CACurrentMediaTime(), serial: session.cursorSerial, isText: session.cursorIsText) {
                    self.prefersProse = self.autocorrectChoice ?? !RemoteWindowView.isCodeApp(target)
                    self.model?.keyboardVisible = wanted
                    return
                }
            }
        }
    }

    func endInteraction() {
        zoomGesture.reset()
        focusTask?.cancel()
        focusTask = nil
        perform(gestures.cancelled())
        resignFirstResponder()
        LaptopPointer.shared.clear(owner: self)
        desktop?.pointerHovering = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { endInteraction() }
    }

    // MARK: Keyboard: typed text goes to the focused Linux window.

    override var canBecomeFirstResponder: Bool { inputEnabled && session?.state == .ready }

    private var focusedWindow: RemoteWindow? {
        if let target { return target }
        guard let session, let desktop else { return nil }
        return desktop.stacking.reversed().compactMap { session.windows[$0] }.first { !$0.isOverrideRedirect && desktop.isVisible($0.id) }
    }

    override func insertText(_ text: String) {
        let modified = hasStickyModifiers
        super.insertText(text)
        if !modified, (text == "\n" || text == "\r" || text == "\r\n"), !RemoteWindowView.isCodeApp(focusedWindow) {
            dismissKeyboard()
        }
    }

    override func dismissKeyboard() {
        if inlineKeyboardControls { dismissInline?() }
        focusTask?.cancel()
        focusTask = nil
        model?.keyboardVisible = false
        super.dismissKeyboard()
    }

    override func sendKey(_ stroke: KeyStroke, modifiers: [String]) {
        session?.key(stroke, pressed: true, in: focusedWindow, extraModifiers: modifiers)
        session?.key(stroke, pressed: false, in: focusedWindow, extraModifiers: modifiers)
    }

    override func send(_ edits: [TypingBuffer.Edit]) { session?.edit(edits, in: focusedWindow) }

    override var sendsMarkedTextAsPreedit: Bool { session?.composesText ?? false }

    override func sendPreedit(_ text: String, selection: NSRange) { session?.compose(text, selection: selection, in: focusedWindow) }
}

struct TrackpadGestureGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Point and click") {
                    Label("Move one finger to point; tap to click; double-tap to open.", systemImage: "cursorarrow")
                    Label("Tap with two fingers to right-click.", systemImage: "hand.tap")
                    Label("Move three fingers to drag; lift any finger to release. Tap then drag also works.", systemImage: "hand.draw")
                }
                Section("Scroll and zoom") {
                    Label("Move two fingers together to scroll in either direction.", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    Label("Pinch two fingers to zoom in apps that support Control–Plus and Control–Minus.", systemImage: "plus.magnifyingglass")
                }
                Section("Windows") {
                    Label("Swipe four fingers left or right to switch windows.", systemImage: "macwindow.on.rectangle")
                    Label("Swipe four fingers up to choose a window; down to dismiss the chooser. From an app card, swipe up to return to Desktop.", systemImage: "square.stack.3d.up")
                }
                Section {
                    Text("iOS can reserve system-edge and accessibility gestures. Force Touch and app-specific rotation gestures are not emulated.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Trackpad Gestures")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
