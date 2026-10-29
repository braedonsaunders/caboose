import CabooseKit
import SwiftUI
import UIKit

/// Laptop's Gamepad mode: an on-screen controller across the lower panel, aimed at the window
/// the trackpad would type into. A game this device runs gets it as a controller through its
/// Gamepad API; any other window gets the keys assigned in Customize, held while the control is.
struct GamepadPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("caboose.laptop.gamepad") private var stored = Data()
    /// The window the pad drives now.
    let target: () -> RemoteWindow?
    let enabled: Bool
    @State private var driver = GamepadDriver()
    @State private var customizing = false

    private var settings: LaptopGamepad.Settings { LaptopGamepad.Settings.decode(stored) }

    var body: some View {
        let settings = settings
        GeometryReader { proxy in
            let items = LaptopGamepad.items(in: proxy.size, settings: settings)
            ZStack(alignment: .topLeading) {
                ForEach(items, id: \.control) { item in
                    GamepadControlView(control: item.control, state: driver.state)
                        .frame(width: item.frame.width, height: item.frame.height)
                        .position(x: item.frame.midX, y: item.frame.midY)
                }
                GamepadTouchArea(items: items, enabled: enabled) { held in
                    driver.apply(LaptopGamepad.state(held: held, items: items), to: target(),
                                 session: model.session, settings: settings)
                }
                VStack(spacing: 4) {
                    Button("Customize Gamepad", systemImage: "slider.horizontal.3") { customizing = true }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 36)
                    Text(driver.destination(of: target(), settings: settings))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityLabel(driver.destination(of: target(), settings: settings))
                }
                .frame(width: proxy.size.width)
                .padding(.top, 8)
            }
        }
        .background(Color(white: 0.1))
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Gamepad")
        .sheet(isPresented: $customizing) { GamepadCustomizer(stored: $stored) }
        .onChange(of: enabled) { _, enabled in if !enabled { driver.release() } }
        .onDisappear { driver.release() }
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
    /// What the keys held in `window` were pressed for.
    @ObservationIgnored private var keyState = GameGamepadState()
    @ObservationIgnored private var keySettings = LaptopGamepad.Settings()
    @ObservationIgnored private let haptics = UIImpactFeedbackGenerator(style: .light)
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.release() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// What the caption under Customize says the pad drives.
    func destination(of window: RemoteWindow?, settings: LaptopGamepad.Settings) -> String {
        guard let window else { return "Choose a window to play" }
        let name = window.title.isEmpty ? "this window" : window.title
        return window.game != nil && settings.games == .controller ? "Controller for \(name)" : "Keys to \(name)"
    }

    func apply(_ new: GameGamepadState, to target: RemoteWindow?, session: (any DisplaySession)?, settings: LaptopGamepad.Settings) {
        if target !== window || session !== self.session || settings != keySettings {
            release()
            window = target
            self.session = session
            keySettings = settings
        }
        let old = state
        state = new
        guard let target, let session, session.state == .ready, session.windows[target.id] === target else { return }
        if settings.haptics, LaptopGamepad.assignableButtons.contains(where: { new[$0] > 0.5 && old[$0] <= 0.5 }) {
            haptics.impactOccurred()
        }
        if let game = target.game, settings.games == .controller {
            self.game = game
            game.gamepad = new
            return
        }
        for change in LaptopGamepad.keyChanges(from: keyState, to: new, settings: settings) {
            guard let stroke = LaptopGamepad.stroke(for: change.name) else { continue }
            session.key(stroke, pressed: change.pressed, in: target)
        }
        keyState = new
    }

    /// Lets go of everything: a game's controller disconnects, held keys go up.
    func release() {
        game?.gamepad = nil
        game = nil
        if let window, let session, session.state == .ready, session.windows[window.id] === window {
            for change in LaptopGamepad.keyChanges(from: keyState, to: GameGamepadState(), settings: keySettings) {
                guard let stroke = LaptopGamepad.stroke(for: change.name) else { continue }
                session.key(stroke, pressed: change.pressed, in: window)
            }
        }
        keyState = GameGamepadState()
        state = GameGamepadState()
    }
}

/// Raw multi-touch over the pad: each finger belongs to the control it went down on until it
/// lifts, so a thumb can roll across the stick or the d-pad without letting go.
private struct GamepadTouchArea: UIViewRepresentable {
    let items: [LaptopGamepad.Item]
    let enabled: Bool
    let changed: ([(control: LaptopGamepad.Control, point: CGPoint)]) -> Void

    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.items = items
        view.changed = changed
        if !enabled { view.clear() }
        view.isUserInteractionEnabled = enabled
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.clear() }

    final class Surface: UIView {
        var items: [LaptopGamepad.Item] = []
        var changed: (([(control: LaptopGamepad.Control, point: CGPoint)]) -> Void)?
        private var fingers: [ObjectIdentifier: (control: LaptopGamepad.Control, point: CGPoint)] = [:]

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches {
                let point = touch.location(in: self)
                if let control = LaptopGamepad.control(at: point, in: items) { fingers[ObjectIdentifier(touch)] = (control, point) }
            }
            report()
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches where fingers[ObjectIdentifier(touch)] != nil {
                fingers[ObjectIdentifier(touch)]?.point = touch.location(in: self)
            }
            report()
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { clear() }
        }

        func clear() {
            guard !fingers.isEmpty else { return }
            fingers.removeAll()
            report()
        }
        private func lift(_ touches: Set<UITouch>) {
            for touch in touches { fingers[ObjectIdentifier(touch)] = nil }
            report()
        }
        private func report() { changed?(Array(fingers.values)) }
    }
}

/// One control, drawn from the pad's state.
private struct GamepadControlView: View {
    let control: LaptopGamepad.Control
    let state: GameGamepadState

    var body: some View {
        switch control {
        case .button(let button):
            let pressed = state[button] > 0.5
            let face = [.south, .east, .west, .north].contains(button)
            let shape = face ? AnyShape(Circle()) : AnyShape(Capsule())
            Text(LaptopGamepad.title(button))
                .font(face ? .title2.weight(.semibold) : .footnote.weight(.semibold))
                .minimumScaleFactor(0.6)
                .foregroundStyle(face ? Self.tint(button) : Color.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(Color.white.opacity(pressed ? 0.32 : 0.1)))
                .overlay(shape.stroke(face ? Self.tint(button).opacity(0.7) : Color.white.opacity(0.25), lineWidth: 1.5))
                .scaleEffect(pressed ? 0.92 : 1)
                .animation(.easeOut(duration: 0.06), value: pressed)
        case .dpad:
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let arm = side * 0.34
                ZStack {
                    RoundedRectangle(cornerRadius: arm * 0.25).fill(Color.white.opacity(0.1)).frame(width: arm, height: side)
                    RoundedRectangle(cornerRadius: arm * 0.25).fill(Color.white.opacity(0.1)).frame(width: side, height: arm)
                    ForEach([GameGamepadState.Button.up, .down, .left, .right], id: \.self) { direction in
                        Image(systemName: Self.arrow(direction))
                            .font(.system(size: arm * 0.38, weight: .bold))
                            .foregroundStyle(Color.white.opacity(state[direction] > 0.5 ? 1 : 0.55))
                            .frame(width: arm, height: arm)
                            .background(RoundedRectangle(cornerRadius: arm * 0.2).fill(Color.white.opacity(state[direction] > 0.5 ? 0.3 : 0)))
                            .offset(Self.offset(direction, by: (side - arm) / 2))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        case .leftStick, .rightStick:
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let x = control == .leftStick ? state[GameGamepadState.Axis.leftX] : state[GameGamepadState.Axis.rightX]
                let y = control == .leftStick ? state[GameGamepadState.Axis.leftY] : state[GameGamepadState.Axis.rightY]
                ZStack {
                    Circle().fill(Color.white.opacity(0.08)).overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1.5))
                    Circle().fill(Color.white.opacity(x != 0 || y != 0 ? 0.4 : 0.22))
                        .frame(width: side * 0.46, height: side * 0.46)
                        .offset(x: CGFloat(x) * side * 0.27, y: CGFloat(y) * side * 0.27)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    static func tint(_ button: GameGamepadState.Button) -> Color {
        switch button {
        case .south: .green
        case .east: .red
        case .west: .blue
        case .north: .yellow
        default: .white
        }
    }

    static func arrow(_ direction: GameGamepadState.Button) -> String {
        switch direction {
        case .up: "arrowtriangle.up.fill"
        case .down: "arrowtriangle.down.fill"
        case .left: "arrowtriangle.left.fill"
        default: "arrowtriangle.right.fill"
        }
    }

    static func offset(_ direction: GameGamepadState.Button, by distance: CGFloat) -> CGSize {
        switch direction {
        case .up: CGSize(width: 0, height: -distance)
        case .down: CGSize(width: 0, height: distance)
        case .left: CGSize(width: -distance, height: 0)
        default: CGSize(width: distance, height: 0)
        }
    }
}

/// The pad's arrangement, feel, and the keys each control presses in windows that do not take
/// a controller.
private struct GamepadCustomizer: View {
    @Binding var stored: Data
    @Environment(\.dismiss) private var dismiss
    @State private var settings = LaptopGamepad.Settings()

    var body: some View {
        NavigationStack {
            Form {
                Section("Layout") {
                    Picker("Left side", selection: $settings.left) {
                        Text("D-pad").tag(LaptopGamepad.LeftControl.dpad)
                        Text("Stick").tag(LaptopGamepad.LeftControl.stick)
                    }
                    Toggle("Right stick", isOn: $settings.showsRightStick)
                    Toggle("Triggers (L2 and R2)", isOn: $settings.showsTriggers)
                    LabeledContent("Size") {
                        Slider(value: $settings.scale, in: 0.8 ... 1.25)
                    }
                    Toggle("Haptics", isOn: $settings.haptics)
                }
                Section {
                    Picker("Games on this device get", selection: $settings.games) {
                        Text("A controller").tag(LaptopGamepad.GameRoute.controller)
                        Text("Keys").tag(LaptopGamepad.GameRoute.keys)
                    }
                } footer: {
                    Text("A game running on this device sees a standard controller through its Gamepad API. Every other window receives the keys below, held for as long as the control is. The computer gets no controller device.")
                }
                Section("Keys") {
                    stickPicker("D-pad", selection: $settings.dpadKeys)
                    stickPicker("Left stick", selection: $settings.leftStickKeys)
                    stickPicker("Right stick", selection: $settings.rightStickKeys)
                    ForEach(LaptopGamepad.assignableButtons, id: \.self) { button in
                        Picker(LaptopGamepad.title(button), selection: keyBinding(button)) {
                            ForEach(LaptopGamepad.keyChoices, id: \.name) { choice in Text(choice.title).tag(choice.name) }
                        }
                    }
                }
                Section {
                    Button("Restore Defaults", role: .destructive) { settings = LaptopGamepad.Settings() }
                }
            }
            .navigationTitle("Customize Gamepad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { settings = LaptopGamepad.Settings.decode(stored) }
        .onChange(of: settings) { _, settings in stored = settings.encoded }
    }

    private func stickPicker(_ title: String, selection: Binding<LaptopGamepad.StickKeys>) -> some View {
        Picker(title, selection: selection) {
            ForEach(LaptopGamepad.StickKeys.allCases, id: \.self) { keys in Text(keys.title).tag(keys) }
        }
    }

    private func keyBinding(_ button: GameGamepadState.Button) -> Binding<String> {
        Binding(get: { settings.keys[LaptopGamepad.name(button)] ?? "" },
                set: { settings.keys[LaptopGamepad.name(button)] = $0 })
    }
}
