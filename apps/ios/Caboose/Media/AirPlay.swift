import AVFoundation
import AVKit
import CabooseKit
import Observation
import SwiftUI
import UIKit

/// Where the computer's sound plays, and the AirPlay device it last played on.
///
/// iOS gives apps no way to choose an AirPlay device themselves or to start Screen
/// Mirroring. What it does give is long-form video routing: a session that asks for it joins
/// the AirPlay device other video apps use, and `prepareRouteSelectionForPlayback` lets the
/// system reconnect the device it suggests (Settings › General › AirPlay & Continuity ›
/// Automatically AirPlay) or ask which device to use. Anything else goes through the
/// system's own route picker (`AirPlayRoutePicker`).
@MainActor @Observable
final class AirPlayCenter {
    /// The AirPlay device playing the computer's sound now, if any.
    private(set) var current: AirPlayRoute?
    /// The AirPlay device the phone last played on, kept across launches.
    private(set) var last: AirPlayRoute?
    /// Whether an AirPlay device is in reach, while Home is watching.
    private(set) var devicesNearby = false
    private(set) var connecting = false
    /// What happened on the last connect, when it was not a connection.
    var notice: String?

    private let detector = AVRouteDetector()
    private var observers: [NSObjectProtocol] = []
    private var watchers = 0
    private static let lastKey = "caboose.airplay.last"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.lastKey) {
            last = try? JSONDecoder().decode(AirPlayRoute.self, from: data)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: .AVRouteDetectorMultipleRoutesDetectedDidChange, object: detector, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.devicesNearby = self?.detector.multipleRoutesDetected ?? false }
        })
        refresh()
    }

    /// Looks for AirPlay devices while a screen that offers AirPlay is showing. Route
    /// detection costs power, so it runs only between `startWatching` and `stopWatching`.
    func startWatching() {
        watchers += 1
        detector.isRouteDetectionEnabled = true
        devicesNearby = detector.multipleRoutesDetected
        refresh()
    }

    func stopWatching() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { detector.isRouteDetectionEnabled = false }
    }

    func refresh() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
            AirPlayRoute.Output(type: $0.portType.rawValue, uid: $0.uid, name: $0.portName)
        }
        current = AirPlayRoute.active(in: outputs)
        let remembered = AirPlayRoute.remembered(after: outputs, previous: last)
        if remembered != last {
            last = remembered
            if let data = try? JSONEncoder().encode(remembered) { UserDefaults.standard.set(data, forKey: Self.lastKey) }
        }
        // Back on the phone: the computer's sound mixes with other apps again.
        if current == nil, AVAudioSession.sharedInstance().routeSharingPolicy == .longFormVideo { Self.configureDefault() }
    }

    /// The computer's sound plays like a video app's, follows the system's route, and mixes
    /// with whatever else is playing.
    static func configureDefault() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
    }

    /// Asks the system to play the computer's sound on AirPlay: it reconnects the device it
    /// suggests or asks which one, as the owner's Automatically AirPlay setting says.
    func connect() {
        guard !connecting else { return }
        notice = nil
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
            try session.setActive(true)
        } catch {
            notice = error.localizedDescription
            return
        }
        connecting = true
        session.prepareRouteSelectionForPlayback { [weak self] _, selection in
            Task { @MainActor in
                guard let self else { return }
                self.connecting = false
                self.refresh()
                if selection != .external, self.current == nil {
                    self.notice = "Choose a device to play your computer's sound on."
                    Self.configureDefault()
                }
            }
        }
    }
}

/// The system's AirPlay route picker: one tap opens the list of AirPlay devices. Drawn
/// invisibly over a custom control, it makes that control the picker.
struct AirPlayRoutePicker: UIViewRepresentable {
    var visible = true

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        apply(to: view)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) { apply(to: view) }

    private func apply(to view: AVRoutePickerView) {
        view.tintColor = visible ? .white : .clear
        view.activeTintColor = visible ? .systemBlue : .clear
    }
}

/// AirPlay from the desktop's toolbar: the last device in one tap, any other through the
/// system's picker, and what it takes to put the desktop itself on a TV.
struct AirPlaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let airPlay = model.airPlay
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                AirPlayCard()
                ZStack {
                    Label("Choose Another Device", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    // The system's picker, invisible over the button: a tap opens its device list.
                    AirPlayRoutePicker(visible: false)
                }
                .frame(height: 50)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Choose another AirPlay device")
                .accessibilityAddTraits(.isButton)
                Label {
                    Text("To show the desktop on a TV, open Control Center and choose Screen Mirroring. The TV becomes a full desktop and this phone its trackpad.")
                } icon: {
                    Image(systemName: "rectangle.on.rectangle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("AirPlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onAppear { airPlay.startWatching() }
            .onDisappear { airPlay.stopWatching() }
        }
    }
}
