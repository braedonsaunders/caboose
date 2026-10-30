import CabooseKit
import SwiftUI
import UIKit

/// Where the input controls are.
enum InputPlacement: Equatable {
    /// Below Laptop's hinge (or its manual split), beside Laptop's rail. Gamepad fills the panel.
    case laptop(compact: Bool)
    /// Across the phone while a display shows the desktop. Gamepad fills the whole screen.
    case display
}

/// The phone's input for the computer, the same wherever it is: Trackpad, Keyboard & Trackpad,
/// Keyboard or Gamepad. Laptop puts it below the hinge with its rail; a connected display puts
/// it across the phone.
struct InputControls: View {
    @Environment(AppModel.self) private var model
    @State private var surface = TrackpadSurface()
    @State private var gestureHelp = false
    let placement: InputPlacement
    let isCard: Bool
    let enabled: Bool
    @Binding var input: LaptopLayout.Input
    @Binding var systemKeyboard: Bool

    private var laptop: Bool { placement != .display }
    private var compact: Bool { placement == .laptop(compact: true) }
    private var desktop: DesktopModel? { isCard ? nil : model.desktop }
    private var target: RemoteWindow? {
        guard isCard, let parent = model.window(model.presentedWindowID) else { return nil }
        return model.auxiliaryWindows(for: parent).last { !$0.isOverrideRedirect } ?? parent
    }
    /// What the panel shows. On a display, the gamepad fills the screen above the trackpad and
    /// the system keyboard types beside the trackpad alone.
    private var shown: LaptopLayout.Input {
        !laptop && (input == .gamepad || systemKeyboard) ? .trackpad : input
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    // Keyboard mode keeps the trackpad mounted at no height: it is the
                    // responder the keyboard types through.
                    trackpad
                        .frame(height: LaptopLayout.trackpadHeight(shown, available: proxy.size.height))
                        .clipped()
                    if shown.showsKeyboard {
                        VStack(spacing: 0) {
                            LaptopKeyHeader(surface: surface).frame(maxWidth: .infinity).frame(height: 48)
                            LaptopComboKeyboard(onText: { surface.insertText($0) },
                                                onKey: { surface.performKeyboardAction(.key($0)) },
                                                onNativeKeyboard: openSystemKeyboard)
                        }
                        .background(Color(uiColor: .systemGray5))
                    }
                    if shown == .gamepad {
                        // A card's target comes from the model, the desktop's front window from the
                        // desktop, so the panel sees either change as it happens.
                        GamepadPanel(target: { isCard ? target : surface.focusedWindow }, enabled: enabled)
                    }
                }
            }
            if laptop {
                Divider()
                rail.frame(width: 56)
            }
        }
        .background(shown.showsKeyboard ? Color(uiColor: .systemGray5) : Color(white: 0.14))
        .allowsHitTesting(enabled)
        .sheet(isPresented: $gestureHelp) { TrackpadGestureGuide() }
        .fullScreenCover(isPresented: Binding(get: { !laptop && input == .gamepad },
                                              set: { if !$0 && input == .gamepad { input = .trackpad } })) {
            GamepadPanel(target: { surface.focusedWindow }, enabled: enabled, close: { input = .trackpad })
                .environment(model)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
        .onChange(of: input) { _, value in settle(value) }
        .onChange(of: model.keyboardVisible) { _, visible in
            if systemKeyboard {
                if !visible { closeSystemKeyboard() }
                return
            }
            guard visible else { return }
            if laptop {
                // A text field wants the keyboard: Laptop's own answers, beside the trackpad
                // that focused the field. The system keyboard never opens by itself here.
                model.keyboardVisible = false
                if input == .trackpad { input = .combo }
            } else if input != .trackpad {
                // On a display the system keyboard opens over the trackpad alone; the
                // keyboards already type, and the gamepad has the screen.
                model.keyboardVisible = false
            }
        }
        .onChange(of: systemKeyboard) { _, open in
            if !open { closeSystemKeyboard() }
        }
    }

    private var trackpad: some View {
        Trackpad(desktop: desktop, target: target,
                 keyboardVisible: model.keyboardVisible && (laptop ? systemKeyboard : input == .trackpad || systemKeyboard),
                 enabled: enabled, pointerEnabled: shown == .trackpad || shown == .combo,
                 sharedSurface: surface, inlineControls: input.showsKeyboard && !systemKeyboard,
                 bareSystemKeyboard: laptop && systemKeyboard,
                 dismissInline: { input = .trackpad })
            .background(Color(white: 0.12))
            .overlay {
                if shown == .trackpad || shown == .combo {
                    VStack(spacing: 6) {
                        Image(systemName: "hand.draw").font(shown == .combo ? .body : .title2)
                        Text("Trackpad").font(.subheadline.weight(.medium))
                        if shown != .combo && !compact {
                            Text("Tap to click · two fingers to scroll or right-click").font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(8).allowsHitTesting(false)
                }
            }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            if compact {
                // The native keyboard can leave only one row above it. One anchored
                // control retains every action without clipping a second row.
                Menu {
                    InputChoices(input: $input, gestureHelp: $gestureHelp)
                    Divider()
                    windowSwitcher
                    computerActions
                    navigationActions
                } label: { Image(systemName: InputChoices.symbol).frame(width: 48, height: 44) }
                .accessibilityLabel("Laptop controls")
                .accessibilityValue(input.title)
            } else {
                Menu { InputChoices(input: $input, gestureHelp: $gestureHelp) } label: {
                    Image(systemName: InputChoices.symbol).frame(width: 48, height: 44)
                }
                .accessibilityLabel("Input")
                .accessibilityValue(input.title)
                windowSwitcher
                Button("Computer", systemImage: "gearshape") { model.settingsPresented = true }
                    .frame(width: 48, height: 44)
                LifecycleMenu().frame(width: 48, height: 44)
                Menu { navigationActions } label: { Image(systemName: "ellipsis").frame(width: 48, height: 44) }
                    .accessibilityLabel("Laptop controls and navigation")
            }
            Spacer(minLength: 0)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
    }

    @ViewBuilder private var computerActions: some View {
        Button("Computer Settings", systemImage: "gearshape") { model.settingsPresented = true }
        Button("Park", systemImage: "moon.zzz") { Task { try? await model.parkComputer() } }
        if model.computerStatus?.capabilities.restart == true {
            Button("Restart…", systemImage: "arrow.clockwise", role: .destructive) { model.restartConfirmationPresented = true }
        }
    }

    @ViewBuilder private var navigationActions: some View {
        LaptopModeMenu()
        Button("Wallpaper", systemImage: "photo") { model.wallpaperPickerPresented = true }
        Divider()
        if isCard { Button("Desktop", systemImage: "macwindow") { leave(.desktop) } }
        Button("Home", systemImage: "house") { leave(.home) }
        Button("Agents", systemImage: "sparkles") { leave(.agents) }
        Button("Apps", systemImage: "square.grid.2x2") { leave(.apps) }
        if TerminalSlot.isFilled { Button("Terminal", systemImage: "apple.terminal") { leave(.terminal) } }
    }

    private var windowSwitcher: some View {
        Menu {
            ForEach(model.workspaceWindows) { window in
                Button(window.title.isEmpty ? model.appName(for: window) : window.title) {
                    if isCard { model.presentedWindowID = window.id }
                    else { model.desktop.activate(window.id, session: model.session) }
                }
            }
        } label: { Image(systemName: "macwindow.on.rectangle").frame(width: 48, height: 44) }
        .accessibilityLabel("Switch window")
    }

    /// A new input: whatever the last one held ends, and the keyboards follow it.
    private func settle(_ value: LaptopLayout.Input) {
        surface.endInteraction()
        systemKeyboard = false
        surface.inlineKeyboardControls = value.showsKeyboard
        model.keyboardVisible = false
    }

    /// The globe key: the system keyboard, for what the phone's own keyboard does not type.
    private func openSystemKeyboard() {
        systemKeyboard = true
        surface.inlineKeyboardControls = false
        model.keyboardVisible = true
    }

    private func closeSystemKeyboard() {
        systemKeyboard = false
        surface.inlineKeyboardControls = input.showsKeyboard
        if model.keyboardVisible { model.keyboardVisible = false }
    }

    private func leave(_ tab: ShellTab) {
        model.keyboardVisible = false
        model.presentedWindowID = nil
        model.selectedTab = tab
    }
}

/// The input choices, the same in Laptop's rail and on a display's trackpad screen.
struct InputChoices: View {
    /// The input menu's one icon, the same in every mode; the menu marks the current mode.
    static let symbol = "switch.2"
    @Binding var input: LaptopLayout.Input
    @Binding var gestureHelp: Bool

    var body: some View {
        Picker("Input", selection: $input) {
            ForEach(LaptopLayout.Input.allCases, id: \.self) { choice in
                Label(choice.title, systemImage: choice.symbol).tag(choice)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Button("Trackpad Gestures", systemImage: "hand.draw") { gestureHelp = true }
    }
}
