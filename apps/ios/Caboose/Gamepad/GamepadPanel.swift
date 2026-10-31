import CabooseKit
import SwiftUI
import UIKit

/// The on-screen controller: below Laptop's hinge in Gamepad mode, and across the whole phone
/// while a display shows the desktop. It drives the window the keyboard would type into. A
/// game this device runs gets it as a controller through its Gamepad API; any other window gets
/// the keys assigned in Customize, held while the control is, or the computer's gamepad device
/// for it when the owner chooses a Linux controller. Each app keeps the controller type last
/// chosen for it.
struct GamepadPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("caboose.laptop.gamepad") private var stored = Data()
    /// The window the pad drives now.
    let target: () -> RemoteWindow?
    let enabled: Bool
    /// Leaves a pad that fills the screen; nil where the pad is one of Laptop's modes.
    var close: (() -> Void)? = nil
    @State private var driver = GamepadDriver()
    @State private var customizing = false
    /// Where each held stick is centred, for drawing a floating one under its thumb.
    @State private var stickCenters: [OnScreenGamepad.Control: CGPoint] = [:]
    /// Bumped to take every finger on the pad away from what it held.
    @State private var ownership = 0
    /// The quick keys show in the strip in place of its title, and the system keyboard
    /// types into the window, for what no control is assigned (a game's Y/N question).
    @State private var quickKeys = false
    @State private var typing = false

    private var settings: OnScreenGamepad.Settings { OnScreenGamepad.Settings.decode(stored) }

    /// What the pad's presses belong to. When any of it changes, everything held is released
    /// and the fingers on the pad let go of their controls, so a press made for one window,
    /// game or arrangement never continues into another.
    private struct Destination: Equatable {
        var window: ObjectIdentifier?
        var session: ObjectIdentifier?
        var game: ObjectIdentifier?
        var live = false
    }

    private func destination(_ window: RemoteWindow?) -> Destination {
        let session = model.session
        return Destination(window: window.map(ObjectIdentifier.init), session: session.map { ObjectIdentifier($0 as AnyObject) },
                           game: window?.game.map(ObjectIdentifier.init),
                           live: window.map { window in session?.state == .ready && session?.windows[window.id] === window } ?? false)
    }

    private func letGo() {
        driver.release()
        stickCenters = [:]
        ownership += 1
    }

    var body: some View {
        let settings = settings
        let current = target()
        let app = current?.appClass?.instance
        let style = settings.style(for: app)
        GeometryReader { proxy in
            let layout = OnScreenGamepad.layout(in: proxy.size, style: style, settings: settings)
            ZStack(alignment: .topLeading) {
                GamepadFace(layout: layout, state: driver.state, centers: stickCenters, settings: settings)
                    .allowsHitTesting(false)
                GamepadTouchArea(layout: layout, sticks: settings.sticks, enabled: enabled && !customizing, ownership: ownership) { state, centers in
                    stickCenters = centers
                    driver.apply(state, to: target(), session: model.session, settings: settings, devices: model.devices)
                }
                GameKeyboard(active: $typing) { stroke in
                    guard let window = target(), let session = model.session, session.state == .ready,
                          session.windows[window.id] === window else { return }
                    session.key(stroke, pressed: true, in: window)
                    session.key(stroke, pressed: false, in: window)
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                hud(style: style, app: app, window: current, settings: settings)
                    .frame(width: max(0, layout.hud.width), height: max(0, layout.hud.height))
                    .position(x: layout.hud.midX, y: layout.hud.midY)
            }
        }
        .background { GamepadBackdrop(style: style).ignoresSafeArea() }
        .buttonStyle(.plain)
        // A thumb at the edge plays rather than pulling in Control Center or going home.
        .defersSystemGestures(on: .all)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(style.title) controller")
        .sheet(isPresented: $customizing) {
            GamepadCustomizer(stored: $stored, app: app, appName: current.map { model.appName(for: $0) })
        }
        .onChange(of: enabled) { _, enabled in if !enabled { letGo() } }
        .onChange(of: destination(current)) { letGo() }
        .onChange(of: stored) { letGo() }
        .onChange(of: customizing) { _, open in if open { letGo() } }
        // The computer has a gamepad for the pad while it shows with the Linux controller output.
        .onChange(of: settings.windows, initial: true) { _, route in model.devices.setScreenGamepad(route == .controller) }
        .onDisappear {
            driver.release()
            model.devices.setScreenGamepad(false)
        }
    }

    /// The pad's own strip: the controller type, where the pad goes, Customize and, for a pad
    /// that fills the screen, the way out.
    private func hud(style: OnScreenGamepad.Style, app: String?, window: RemoteWindow?, settings: OnScreenGamepad.Settings) -> some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Controller", selection: Binding(get: { style }, set: { choice in
                    var next = settings
                    next.choose(choice, for: app)
                    stored = next.encoded
                })) {
                    ForEach(OnScreenGamepad.Style.allCases, id: \.self) { choice in
                        Label(choice.title, systemImage: choice.symbol).tag(choice)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: style.symbol).frame(width: 40, height: 32).contentShape(.rect)
            }
            .accessibilityLabel("Controller type")
            .accessibilityValue(style.title)
            if quickKeys {
                quickKeyStrip(window)
            } else {
                Text(driver.destination(of: window, settings: settings, name: window.map { model.appName(for: $0) },
                                        linux: model.devices.screenGamepadOffered))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            Button(quickKeys ? "Hide Keys" : "Keys", systemImage: quickKeys ? "keyboard.chevron.compact.down" : "keyboard") {
                quickKeys.toggle()
                if !quickKeys { typing = false }
            }
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 32)
                .contentShape(.rect)
            Button("Customize Controller", systemImage: "slider.horizontal.3") { customizing = true }
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 32)
                .contentShape(.rect)
            if let close {
                Button("Done", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 32)
                    .contentShape(.rect)
                    .accessibilityHint("Returns to the trackpad")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
    }
}

extension GamepadPanel {
    /// Keys a game asks for that no control may have: its menus' answers and the console.
    static let quickKeys: [(name: String, title: String)] = [
        ("Escape", "esc"), ("Return", "⏎"), ("y", "Y"), ("n", "N"), ("Tab", "⇥"), ("`", "~"),
    ]

    /// Each key pressed and released at a tap, and the system keyboard for any other.
    func quickKeyStrip(_ window: RemoteWindow?) -> some View {
        HStack(spacing: 0) {
            ForEach(Self.quickKeys, id: \.name) { key in
                Button(key.title) {
                    guard let window, let session = model.session, session.state == .ready,
                          session.windows[window.id] === window,
                          let stroke = OnScreenGamepad.stroke(for: key.name) else { return }
                    session.key(stroke, pressed: true, in: window)
                    session.key(stroke, pressed: false, in: window)
                    if settings.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.8) }
                }
                .font(.caption.weight(.semibold))
                .frame(minWidth: 26, maxWidth: .infinity, minHeight: 32)
                .contentShape(.rect)
                .accessibilityLabel("Press \(key.name)")
            }
            Button("Type", systemImage: "character.cursor.ibeam") { typing.toggle() }
                .labelStyle(.iconOnly)
                .frame(minWidth: 30, minHeight: 32)
                .contentShape(.rect)
                .accessibilityLabel(typing ? "Hide keyboard" : "Type with the keyboard")
        }
        .frame(maxWidth: .infinity)
    }
}

/// The system keyboard for the pad: each character typed, Return and Delete become a key
/// press in the window, as a hardware keyboard's would.
private struct GameKeyboard: UIViewRepresentable {
    @Binding var active: Bool
    let press: (KeyStroke) -> Void

    func makeUIView(context: Context) -> Field { Field() }

    func updateUIView(_ field: Field, context: Context) {
        field.press = press
        field.ended = { active = false }
        DispatchQueue.main.async {
            guard field.window != nil else { return }
            if active, !field.isFirstResponder { field.becomeFirstResponder() }
            if !active, field.isFirstResponder { field.resignFirstResponder() }
        }
    }

    final class Field: UIView, UIKeyInput {
        var press: ((KeyStroke) -> Void)?
        var ended: (() -> Void)?
        var autocorrectionType: UITextAutocorrectionType = .no
        var autocapitalizationType: UITextAutocapitalizationType = .none
        var spellCheckingType: UITextSpellCheckingType = .no
        var smartQuotesType: UITextSmartQuotesType = .no
        override var canBecomeFirstResponder: Bool { true }
        var hasText: Bool { true }

        func insertText(_ text: String) {
            for character in text {
                let stroke = character == "\n" || character == "\r" ? Keysyms.special["Return"] : Keysyms.stroke(for: character)
                if let stroke { press?(stroke) }
            }
        }

        func deleteBackward() {
            if let stroke = Keysyms.special["BackSpace"] { press?(stroke) }
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { ended?() }
            return resigned
        }
    }
}

/// Where the pad's state goes, and what it holds there, so every press gets its release:
/// leaving the mode, a new target, the app going inactive or the session going release it.
@MainActor @Observable
final class GamepadDriver {
    private(set) var state = GameGamepadState()
    @ObservationIgnored private weak var window: RemoteWindow?
    @ObservationIgnored private weak var session: (any DisplaySession)?
    @ObservationIgnored private weak var game: RemoteGame?
    /// Where the pad reaches the computer as a gamepad, while it does.
    @ObservationIgnored private weak var devices: DeviceCenter?
    /// What the keys held in `window` were pressed for.
    @ObservationIgnored private var keyState = GameGamepadState()
    @ObservationIgnored private var keySettings = OnScreenGamepad.Settings()
    @ObservationIgnored private let press = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private let click = UIImpactFeedbackGenerator(style: .medium)
    @ObservationIgnored private let direction = UISelectionFeedbackGenerator()
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.release() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// What the strip says the pad drives; `linux` when the computer has the pad's gamepad.
    func destination(of window: RemoteWindow?, settings: OnScreenGamepad.Settings, name: String?, linux: Bool) -> String {
        guard let window else { return "Choose a window to play" }
        let title = window.title.isEmpty ? (name ?? "this window") : window.title
        if window.game.map({ $0.webview == nil }) == true && settings.games == .controller { return "Controller for \(title)" }
        return settings.windows == .controller && linux ? "Linux controller for \(title)" : "Keys to \(title)"
    }

    func apply(_ new: GameGamepadState, to target: RemoteWindow?, session: (any DisplaySession)?, settings: OnScreenGamepad.Settings,
               devices: DeviceCenter) {
        if target !== window || session !== self.session || settings != keySettings {
            release()
            window = target
            self.session = session
            keySettings = settings
        }
        let old = state
        state = new
        guard let target, let session, session.state == .ready, session.windows[target.id] === target else { return }
        if settings.haptics, let feedback = OnScreenGamepad.feedback(from: old, to: new) {
            switch feedback {
            case .direction: direction.selectionChanged()
            case .press: press.impactOccurred(intensity: 0.8)
            case .click: click.impactOccurred()
            }
        }
        if let game = target.game, game.webview == nil, settings.games == .controller {
            self.game = game
            game.gamepad = new
            return
        }
        if settings.windows == .controller, devices.screenGamepadOffered {
            self.devices = devices
            devices.screenGamepad(new)
            return
        }
        for change in OnScreenGamepad.keyChanges(from: keyState, to: new, settings: settings) {
            Self.send(change, in: target, session: session)
        }
        keyState = new
    }

    /// A key, or keys pressed together: down in order, up in reverse.
    private static func send(_ change: (name: String, pressed: Bool), in window: RemoteWindow, session: any DisplaySession) {
        let strokes = OnScreenGamepad.strokes(for: change.name)
        for stroke in change.pressed ? strokes : strokes.reversed() {
            session.key(stroke, pressed: change.pressed, in: window)
        }
    }

    /// Lets go of everything: a game's controller disconnects, held keys go up.
    func release() {
        game?.gamepad = nil
        game = nil
        devices?.screenGamepad(GameGamepadState())
        devices = nil
        if let window, let session, session.state == .ready, session.windows[window.id] === window {
            for change in OnScreenGamepad.keyChanges(from: keyState, to: GameGamepadState(), settings: keySettings) {
                Self.send(change, in: window, session: session)
            }
        }
        keyState = GameGamepadState()
        state = GameGamepadState()
    }
}

/// Raw multi-touch over the pad, fed to `OnScreenGamepad.Tracker`: each finger belongs to the
/// group it went down on until it lifts, so a thumb can roll across the face buttons or carry
/// a stick past its rim without letting go.
private struct GamepadTouchArea: UIViewRepresentable {
    let layout: OnScreenGamepad.Layout
    let sticks: OnScreenGamepad.StickMode
    let enabled: Bool
    /// A new value takes every finger on the pad away from its control.
    let ownership: Int
    let changed: (GameGamepadState, [OnScreenGamepad.Control: CGPoint]) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.layout = layout
        view.sticks = sticks
        view.changed = changed
        if view.ownership != ownership || !enabled {
            view.ownership = ownership
            view.disown()
        }
        view.isUserInteractionEnabled = enabled
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.clear() }

    final class Surface: UIView {
        var layout = OnScreenGamepad.layout(in: .zero, style: .modern, settings: OnScreenGamepad.Settings())
        var sticks = OnScreenGamepad.StickMode.floating
        var changed: ((GameGamepadState, [OnScreenGamepad.Control: CGPoint]) -> Void)?
        var ownership = 0
        private var tracker = OnScreenGamepad.Tracker()
        /// What was last reported, so a finger that holds nothing reports nothing as it moves.
        private var reported = (state: GameGamepadState(), centers: [OnScreenGamepad.Control: CGPoint]())

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        private func id(_ touch: UITouch) -> Int { ObjectIdentifier(touch).hashValue }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches { tracker.began(id(touch), at: touch.location(in: self), time: touch.timestamp, in: layout, sticks: sticks) }
            report()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches { tracker.moved(id(touch), to: touch.location(in: self), in: layout, sticks: sticks) }
            report()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { clear() }
        }

        /// Every finger lets go of its control without a report: whoever asked has released
        /// what the pad held.
        func disown() {
            tracker.disown()
            reported = (GameGamepadState(), [:])
        }

        func clear() {
            guard !tracker.isEmpty else { return }
            tracker.clear()
            report()
        }
        private func lift(_ touches: Set<UITouch>) {
            for touch in touches { tracker.ended(id(touch), at: touch.timestamp, in: layout) }
            report()
        }
        private func report() {
            let state = tracker.state(in: layout), centers = tracker.stickCenters
            guard state != reported.state || centers != reported.centers else { return }
            reported = (state, centers)
            changed?(state, centers)
        }
    }
}
