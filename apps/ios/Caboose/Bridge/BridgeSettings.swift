import SwiftUI
import UIKit

/// What the phone does for the computer's applications, kept on this phone.
enum BridgeSettings {
    static let dialogsKey = "bridge.dialogs"
    static let appearanceKey = "bridge.appearance"
    static let nowPlayingKey = "bridge.nowPlaying"
    /// The computers (by identity) location is shared with: `LocationConsent`.
    static let locationKey = "bridge.location.computers"

    static func register() {
        UserDefaults.standard.register(defaults: [dialogsKey: true, appearanceKey: true, nowPlayingKey: true])
    }
    static var dialogs: Bool { UserDefaults.standard.bool(forKey: dialogsKey) }
    static var appearance: Bool { UserDefaults.standard.bool(forKey: appearanceKey) }
    static var nowPlaying: Bool { UserDefaults.standard.bool(forKey: nowPlayingKey) }
}

/// The computer settings' integration section ("iPhone Integration" on an iPhone).
struct NativeBridgeSettingsSection: View {
    let bridge: NativeBridge
    @AppStorage(BridgeSettings.dialogsKey) private var dialogs = true
    @AppStorage(BridgeSettings.appearanceKey) private var appearance = true
    @AppStorage(BridgeSettings.nowPlayingKey) private var nowPlaying = true
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
            // Consent is for this computer only; another paired computer asks again.
            Toggle(isOn: Binding(get: { bridge.sharesLocation }, set: { bridge.setSharesLocation($0) })) {
                Label { Text("Share Location with This Computer") } icon: { Image(systemName: "location") }
            }
            .disabled(bridge.computerID == nil)
            if bridge.sharesLocation, let problem = bridge.locationProblem {
                Text(problem).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("\(device) Integration")
        } footer: {
            Text("Linux apps open files from Files, Photos, the camera and the document scanner, save with \(device) sheets, follow your appearance and text size, and show their audio in Now Playing. Location is shared only while Caboose is open.")
        }
    }
}
