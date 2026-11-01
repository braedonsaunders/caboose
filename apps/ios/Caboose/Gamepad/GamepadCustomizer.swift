import CabooseKit
import SwiftUI

/// The controller type for the app the pad drives, how the pad feels, and the key each
/// control presses in windows that do not take a controller.
struct GamepadCustomizer: View {
    @Binding var stored: Data
    /// The window class of the app the pad drives, which keeps its own controller type.
    let app: String?
    let appName: String?
    @Environment(\.dismiss) private var dismiss
    @State private var settings = OnScreenGamepad.Settings()

    private var style: OnScreenGamepad.Style { settings.style(for: app) }
    private var modernLayout: OnScreenGamepad.ModernLayout { settings.modernLayout(for: app) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(OnScreenGamepad.Style.allCases, id: \.self) { choice in
                            StyleCard(style: choice, settings: settings, app: app, selected: choice == style) {
                                settings.choose(choice, for: app)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Controller")
                } footer: {
                    if let appName { Text("\(appName) keeps the controller chosen for it.") }
                }

                if style == .modern {
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                            ForEach(OnScreenGamepad.ModernLayout.allCases, id: \.self) { choice in
                                ModernLayoutCard(modernLayout: choice, settings: settings, selected: choice == modernLayout) {
                                    settings.chooseModernLayout(choice, for: app)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Modern View")
                    } footer: {
                        Text("Places triggers and bumpers where your thumbs reach without stretching to the top of the screen.")
                    }
                }

                Section {
                    if style.takesLabels {
                        Picker("Button labels", selection: $settings.labels) {
                            ForEach(OnScreenGamepad.Labels.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    if style.hasSticks {
                        Picker("Sticks", selection: $settings.sticks) {
                            ForEach(OnScreenGamepad.StickMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    if style == .modern {
                        Toggle("Aim while firing (drag RT / LT)", isOn: $settings.triggerAim)
                    }
                    LabeledContent("Size") {
                        Slider(value: $settings.scale, in: OnScreenGamepad.Settings.scaleRange)
                    }
                    Toggle("Haptics", isOn: $settings.haptics)
                } header: {
                    Text("Feel")
                } footer: {
                    Text(feelNote)
                }

                Section {
                    Picker("Games on this device get", selection: $settings.games) {
                        Text("A controller").tag(OnScreenGamepad.GameRoute.controller)
                        Text("Keys").tag(OnScreenGamepad.GameRoute.keys)
                    }
                    Picker("Other windows get", selection: $settings.windows) {
                        Text("Automatic").tag(OnScreenGamepad.WindowRoute.automatic)
                        Text("Keys").tag(OnScreenGamepad.WindowRoute.keys)
                        Text("A Linux controller").tag(OnScreenGamepad.WindowRoute.controller)
                    }
                } footer: {
                    Text("A game running on this device sees a standard controller through its Gamepad API. Every other window receives the keys below, held for as long as the control is, or, as a Linux controller, a gamepad on the computer that Steam and SDL games use, with both sticks and triggers. Automatic is the Linux controller while a game on the computer reads it and the keys otherwise. The Linux controller needs Controllers on in the computer's hardware settings; without it the keys are pressed.")
                }

                Section {
                    stickPicker(style == .arcade ? "Lever" : "D-pad", selection: $settings.dpadKeys, analog: false)
                    if style.hasSticks {
                        stickPicker("Left stick", selection: $settings.leftStickKeys)
                        stickPicker("Right stick", selection: $settings.rightStickKeys)
                        if settings.leftStickKeys == .mouse || settings.rightStickKeys == .mouse {
                            LabeledContent("Look speed") {
                                Slider(value: $settings.lookSpeed, in: OnScreenGamepad.Settings.lookSpeedRange)
                            }
                        }
                    }
                    ForEach(style.buttons, id: \.self) { button in
                        Picker(title(button), selection: keyBinding(button)) {
                            ForEach(OnScreenGamepad.keyChoices, id: \.name) { choice in Text(choice.title).tag(choice.name) }
                        }
                    }
                } header: {
                    Text("Keys")
                } footer: {
                    Text("A key belongs to the button's place on the controller, so it carries across types: B on Classic is A on Modern.")
                }

                Section {
                    Button("Restore Defaults", role: .destructive) { settings = OnScreenGamepad.Settings() }
                }
            }
            .navigationTitle("Customize Controller")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .onAppear { settings = OnScreenGamepad.Settings.decode(stored) }
        .onChange(of: settings) { _, settings in stored = settings.encoded }
    }

    private var feelNote: String {
        var note = "Slide a thumb across the buttons to press each in turn, or rest it between two to press both."
        if style.hasSticks {
            note += " Tap then press a stick to click it. A trigger pulls fully when touched; slide down to ease it off."
        }
        if style == .modern {
            note += " With Aim while firing on, dragging a thumb on RT or LT steers the right stick while keeping the trigger pulled."
        }
        return note
    }

    private func title(_ button: GameGamepadState.Button) -> String {
        switch button {
        case .leftStick: "Left Stick Click"
        case .rightStick: "Right Stick Click"
        default: OnScreenGamepad.label(button, style: style, labels: settings.labels).name
        }
    }

    /// A stick's choices; mouse look needs an analog stick, not a d-pad or lever.
    private func stickPicker(_ title: String, selection: Binding<OnScreenGamepad.StickKeys>, analog: Bool = true) -> some View {
        Picker(title, selection: selection) {
            ForEach(OnScreenGamepad.StickKeys.allCases.filter { analog || $0 != .mouse }, id: \.self) { keys in
                Text(keys.title).tag(keys)
            }
        }
    }

    private func keyBinding(_ button: GameGamepadState.Button) -> Binding<String> {
        Binding(get: { settings.keys[OnScreenGamepad.name(button)] ?? "" },
                set: { settings.keys[OnScreenGamepad.name(button)] = $0 })
    }
}

/// A controller type as a card: the pad itself, drawn small, and what it has.
private struct StyleCard: View {
    let style: OnScreenGamepad.Style
    let settings: OnScreenGamepad.Settings
    let app: String?
    let selected: Bool
    let choose: () -> Void

    /// The pad is laid out at a phone's landscape size and drawn down to the card.
    private static let canvas = CGSize(width: 720, height: 340)

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.canvas.width
                    GamepadFace(layout: OnScreenGamepad.layout(in: Self.canvas, style: style, settings: settings, app: app),
                                state: GameGamepadState(), centers: [:], settings: settings)
                        .frame(width: Self.canvas.width, height: Self.canvas.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
                .background { GamepadBackdrop(style: style) }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Label(style.title, systemImage: selected ? "checkmark.circle.fill" : style.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                Text(style.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A Modern controller view as a preview card: shows where RT/RB and LT/LB sit relative to
/// the sticks, D-pad, and face buttons.
private struct ModernLayoutCard: View {
    let modernLayout: OnScreenGamepad.ModernLayout
    let settings: OnScreenGamepad.Settings
    let selected: Bool
    let choose: () -> Void

    private static let canvas = CGSize(width: 720, height: 340)

    var body: some View {
        var previewSettings = settings
        let _ = {
            previewSettings.modernLayout = modernLayout
            previewSettings.appModernLayouts = [:]
        }()
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.canvas.width
                    GamepadFace(layout: OnScreenGamepad.layout(in: Self.canvas, style: .modern, settings: previewSettings),
                                state: GameGamepadState(), centers: [:], settings: previewSettings)
                        .frame(width: Self.canvas.width, height: Self.canvas.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
                .aspectRatio(Self.canvas.width / Self.canvas.height, contentMode: .fit)
                .background { GamepadBackdrop(style: .modern) }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                Label(modernLayout.title, systemImage: selected ? "checkmark.circle.fill" : modernLayout.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                Text(modernLayout.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
