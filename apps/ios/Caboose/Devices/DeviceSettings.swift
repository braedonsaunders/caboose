import CabooseKit
import SwiftUI
import UIKit

/// What of the phone's hardware the computer may use (docs/devices.md), kept on this phone.
/// Cameras and the microphone are allowed per computer, as location is; the rest apply to
/// every computer.
enum DeviceSettings {
    static let camerasKey = "devices.cameras.computers"
    static let microphoneKey = "devices.microphone.computers"
    static let motionKey = "devices.motion"
    static let controllersKey = "devices.controllers"
    static let buttonsKey = "devices.buttons"
    static let batteryKey = "devices.battery"

    static func register() {
        UserDefaults.standard.register(defaults: [motionKey: true, controllersKey: true, buttonsKey: true, batteryKey: true])
    }

    static func consent(_ key: String) -> LocationConsent {
        LocationConsent(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func setConsent(_ key: String, _ allowed: Bool, for computer: String) {
        var consent = consent(key)
        consent.set(allowed, for: computer)
        UserDefaults.standard.set(consent.stored, forKey: key)
    }

    /// What the computer `computer` (its identity) may use.
    static func permissions(for computer: String?) -> DevicePermissions {
        let defaults = UserDefaults.standard
        return DevicePermissions(cameras: consent(camerasKey).allows(computer), microphone: consent(microphoneKey).allows(computer),
                                 motion: defaults.bool(forKey: motionKey), controllers: defaults.bool(forKey: controllersKey),
                                 buttons: defaults.bool(forKey: buttonsKey), battery: defaults.bool(forKey: batteryKey))
    }
}

/// The computer settings' hardware section ("iPhone Hardware" on an iPhone): which of the
/// phone's devices the computer sees, and what each became there.
struct DeviceSettingsSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DeviceSettings.motionKey) private var motion = true
    @AppStorage(DeviceSettings.controllersKey) private var controllers = true
    @AppStorage(DeviceSettings.buttonsKey) private var buttons = true
    @AppStorage(DeviceSettings.batteryKey) private var battery = true
    /// Bumped when a per-computer switch changes, so the section reads it again.
    @State private var consentRevision = 0
    private let device = UIDevice.current.model

    private var computer: String? { model.credentials?.fileDomainIdentifier }

    var body: some View {
        let devices = model.devices
        let _ = consentRevision
        Section {
            consentToggle("Cameras", systemImage: "camera", key: DeviceSettings.camerasKey)
            consentToggle("Microphone", systemImage: "mic", key: DeviceSettings.microphoneKey)
            Toggle(isOn: $motion) { Label("Motion Sensors", systemImage: "gyroscope") }
            Toggle(isOn: $controllers) { Label("Controllers", systemImage: "gamecontroller") }
            Toggle(isOn: $buttons) { Label("Buttons", systemImage: "button.vertical.right.press") }
            Toggle(isOn: $battery) { Label("Battery", systemImage: "battery.75percent") }
            ForEach(devices.offered.filter { devices.status[$0.id]?.error != nil || devices.failures[$0.id] != nil }, id: \.id) { offered in
                LabeledContent(offered.name) {
                    Text(devices.failures[offered.id] ?? devices.status[offered.id]?.error ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("\(device) Hardware")
        } footer: {
            Text("While Caboose is open, Linux apps use your \(device)'s cameras, microphone, motion sensors, controllers, buttons and battery as their own devices. Cameras and the microphone run only while an app uses them, and only for computers you turn them on for.")
        }
        .onChange(of: motion) { model.updateDevicePermissions() }
        .onChange(of: controllers) { model.updateDevicePermissions() }
        .onChange(of: buttons) { model.updateDevicePermissions() }
        .onChange(of: battery) { model.updateDevicePermissions() }
    }

    private func consentToggle(_ title: String, systemImage: String, key: String) -> some View {
        Toggle(isOn: Binding(get: { DeviceSettings.consent(key).allows(computer) }, set: { allowed in
            guard let computer else { return }
            DeviceSettings.setConsent(key, allowed, for: computer)
            consentRevision += 1
            model.updateDevicePermissions()
        })) {
            Label(title, systemImage: systemImage)
        }
        .disabled(computer == nil)
    }
}

/// Which of the phone's hardware a computer app is using now, shown over the app while it is.
struct DeviceInUseIndicator: View {
    let devices: DeviceCenter

    var body: some View {
        let kinds = Set(devices.inUse.values)
        if !kinds.isEmpty {
            HStack(spacing: 6) {
                ForEach(Self.order.filter(kinds.contains), id: \.self) { kind in
                    Image(systemName: Self.symbol(kind))
                }
                Text(Self.summary(kinds))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(kinds.contains(.camera) || kinds.contains(.depth) ? .green : kinds.contains(.microphone) ? .orange : .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.summary(kinds))
            .transition(.opacity)
        }
    }

    static let order: [DeviceKind] = [.camera, .depth, .microphone, .motion]

    static func symbol(_ kind: DeviceKind) -> String {
        switch kind {
        case .camera: "camera.fill"
        case .depth: "camera.metering.matrix"
        case .microphone: "mic.fill"
        default: "gyroscope"
        }
    }

    static func summary(_ kinds: Set<DeviceKind>) -> String {
        let names = order.filter(kinds.contains).map { kind in
            switch kind {
            case .camera: "Camera"
            case .depth: "Depth"
            case .microphone: "Microphone"
            default: "Motion"
            }
        }
        return "Computer is using " + ListFormatter.localizedString(byJoining: names)
    }
}
