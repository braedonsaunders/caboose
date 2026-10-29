import SwiftUI
import UIKit

/// What the phone does for the computer's applications, kept on this phone.
enum BridgeSettings {
    static let dialogsKey = "bridge.dialogs"
    static let appearanceKey = "bridge.appearance"
    static let nowPlayingKey = "bridge.nowPlaying"
    static let locationKey = "bridge.location"

    static func register() {
        UserDefaults.standard.register(defaults: [dialogsKey: true, appearanceKey: true, nowPlayingKey: true, locationKey: false])
    }
    static var dialogs: Bool { UserDefaults.standard.bool(forKey: dialogsKey) }
    static var appearance: Bool { UserDefaults.standard.bool(forKey: appearanceKey) }
    static var nowPlaying: Bool { UserDefaults.standard.bool(forKey: nowPlayingKey) }
    static var location: Bool { UserDefaults.standard.bool(forKey: locationKey) }
}

/// The computer settings' integration section ("iPhone Integration" on an iPhone).
struct NativeBridgeSettingsSection: View {
    let bridge: NativeBridge
    @AppStorage(BridgeSettings.dialogsKey) private var dialogs = true
    @AppStorage(BridgeSettings.appearanceKey) private var appearance = true
    @AppStorage(BridgeSettings.nowPlayingKey) private var nowPlaying = true
    @AppStorage(BridgeSettings.locationKey) private var location = false
    private let device = UIDevice.current.model

    var body: some View {
        Section {
            Toggle(isOn: $dialogs) {
                Label { Text("Open and Save with \(device)") } icon: { Image(systemName: "doc.badge.ellipsis") }
            }
            Toggle(isOn: $appearance) {
                Label { Text("Match \(device) Appearance") } icon: { Image(systemName: "circle.lefthalf.filled") }
            }
            .onChange(of: appearance) { _, on in if on { bridge.appearanceSettingChanged() } }
            Toggle(isOn: $nowPlaying) {
                Label { Text("Computer Audio in Now Playing") } icon: { Image(systemName: "play.square.stack") }
            }
            .onChange(of: nowPlaying) { _, _ in bridge.nowPlayingSettingChanged() }
            Toggle(isOn: $location) {
                Label { Text("Share Location with Computer") } icon: { Image(systemName: "location") }
            }
            .onChange(of: location) { _, _ in bridge.locationSettingChanged() }
            if location, let problem = bridge.locationProblem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("\(device) Integration")
        } footer: {
            Text("Linux apps choose files with \(device) pickers, follow your appearance and text size, and show their audio in Now Playing. Location is shared only while Caboose is open.")
        }
    }
}
