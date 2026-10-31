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
        Self.configureDefault()
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
        let wasOnAirPlay = current != nil
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
            AirPlayRoute.Output(type: $0.portType.rawValue, uid: $0.uid, name: $0.portName)
        }
        current = AirPlayRoute.active(in: outputs)
        let remembered = AirPlayRoute.remembered(after: outputs, previous: last)
        if remembered != last {
            last = remembered
            if let data = try? JSONEncoder().encode(remembered) { UserDefaults.standard.set(data, forKey: Self.lastKey) }
        }
        // Restore mixing after leaving an established AirPlay route. A route notification
        // can arrive before a selected device appears in currentRoute.
        if !connecting, wasOnAirPlay, current == nil, AVAudioSession.sharedInstance().routeSharingPolicy == .longFormVideo {
            Self.configureDefault()
        }
    }

    /// The computer's sound plays like a video app's, follows the system's route, and mixes
    /// with whatever else is playing.
    static func configureDefault() {
        try? CabooseAudioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
    }

    /// Asks the system to play the computer's sound on AirPlay: it reconnects the device it
    /// suggests or asks which one, as the owner's Automatically AirPlay setting says.
    func connect() {
        guard !connecting else { return }
        notice = nil
        let session = AVAudioSession.sharedInstance()
        connecting = true
        do {
            try CabooseAudioSession.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
            try session.setActive(true)
        } catch {
            connecting = false
            notice = error.localizedDescription
            Self.configureDefault()
            return
        }
        session.prepareRouteSelectionForPlayback { [weak self] _, selection in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.connecting = false
                if selection != .external, self.current == nil {
                    self.notice = "Not connected"
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
/// system's picker. The desktop itself reaches a TV only through Screen Mirroring, which
/// the owner starts in Control Center.
struct AirPlaySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let airPlay = model.airPlay
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                AirPlayCard()
                ZStack {
                    Label("Other Devices", systemImage: "list.bullet")
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

/// One tap to play on the AirPlay device used last; the picker beside it chooses another.
/// See `AirPlayCenter` for what iOS lets an app do here. Shown in `AirPlaySheet`.
struct AirPlayCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let airPlay = model.airPlay
        let onTV = model.externalDisplayActive
        let playing = airPlay.current != nil || onTV
        HStack(spacing: 14) {
            Button { airPlay.connect() } label: {
                HStack(spacing: 14) {
                    Image(systemName: onTV ? "tv" : "airplay.audio")
                        .font(.title2)
                        .symbolEffect(.pulse, isActive: airPlay.connecting)
                        .foregroundStyle(playing ? Brand.amber : .white)
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular, in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline).lineLimit(1)
                        if let status { Text(status).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(airPlay.connecting || onTV || airPlay.current != nil)
            // The system's own picker: another device, or back to the phone.
            AirPlayRoutePicker()
                .frame(width: 36, height: 36)
                .accessibilityLabel("AirPlay devices")
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }

    private var title: String {
        let airPlay = model.airPlay
        if model.externalDisplayActive { return "Desktop on TV" }
        if let current = airPlay.current { return current.name }
        if let last = airPlay.last { return last.name }
        return "AirPlay"
    }

    private var status: String? {
        let airPlay = model.airPlay
        if model.externalDisplayActive { return "Screen Mirroring" }
        if airPlay.current != nil { return "Playing" }
        if airPlay.connecting { return "Connecting" }
        if let notice = airPlay.notice { return notice }
        return airPlay.last != nil ? "AirPlay" : nil
    }
}
