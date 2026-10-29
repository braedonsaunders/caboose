import CabooseKit
import CoreLocation
import MediaPlayer
import UIKit

/// The computer's media in the system's Now Playing: Control Center, the Lock Screen,
/// AirPods and keyboard media keys control the Linux player. It publishes only metadata
/// and handles commands; the app's audio session is configured where the sound plays.
@MainActor
final class NowPlayingCenter {
    var control: (String, String, Double?) async throws -> Void = { _, _, _ in }
    var suspended = false { didSet { if suspended { publish(nil) } else { publish(state) } } }
    private var state: BridgeNowPlaying?
    private var artwork: (url: URL, image: MPMediaItemArtwork)?
    private var registered = false

    func show(_ next: BridgeNowPlaying) {
        state = next
        register()
        publish(next)
    }

    func stopped(_ id: String) {
        guard state?.id == id else { return }
        clear()
    }

    func clear() {
        state = nil
        publish(nil)
    }

    private func publish(_ shown: BridgeNowPlaying?) {
        let center = MPNowPlayingInfoCenter.default()
        let commands = MPRemoteCommandCenter.shared()
        guard let shown, !suspended else {
            if registered { center.nowPlayingInfo = nil; center.playbackState = .stopped }
            for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand, commands.nextTrackCommand,
                            commands.previousTrackCommand, commands.changePlaybackPositionCommand] { command.isEnabled = false }
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: shown.title.isEmpty ? shown.player : shown.title,
            MPMediaItemPropertyArtist: shown.artist.isEmpty ? shown.player : shown.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: shown.position(at: Date().timeIntervalSince1970 * 1000),
            MPNowPlayingInfoPropertyPlaybackRate: shown.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !shown.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = shown.album }
        if let duration = shown.duration { info[MPMediaItemPropertyPlaybackDuration] = duration } else { info[MPNowPlayingInfoPropertyIsLiveStream] = true }
        if let artwork, artwork.url == shown.artwork { info[MPMediaItemPropertyArtwork] = artwork.image }
        center.nowPlayingInfo = info
        center.playbackState = shown.paused ? .paused : .playing
        commands.playCommand.isEnabled = shown.canPlay
        commands.pauseCommand.isEnabled = shown.canPause
        commands.togglePlayPauseCommand.isEnabled = shown.canPlay || shown.canPause
        commands.nextTrackCommand.isEnabled = shown.canNext
        commands.previousTrackCommand.isEnabled = shown.canPrevious
        commands.changePlaybackPositionCommand.isEnabled = shown.canSeek && shown.duration != nil
        if let url = shown.artwork, artwork?.url != url { load(url) }
    }

    private func load(_ url: URL) {
        Task {
            guard let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 8 * 1024 * 1024, let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            artwork = (url, art)
            if state?.artwork == url { publish(state) }
        }
    }

    private func register() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        let send = { [weak self] (action: String, position: Double?) -> MPRemoteCommandHandlerStatus in
            guard let self, let id = self.state?.id else { return .noActionableNowPlayingItem }
            Task { try? await self.control(id, action, position) }
            return .success
        }
        commands.playCommand.addTarget { _ in send("play", nil) }
        commands.pauseCommand.addTarget { _ in send("pause", nil) }
        commands.togglePlayPauseCommand.addTarget { _ in send("toggle", nil) }
        commands.nextTrackCommand.addTarget { _ in send("next", nil) }
        commands.previousTrackCommand.addTarget { _ in send("previous", nil) }
        commands.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return send("seek", max(0, event.positionTime))
        }
    }
}

/// The phone's location for the computer's GeoClue, while the owner shares it and Caboose
/// is in the foreground and connected.
@MainActor
final class LocationSharing: NSObject, CLLocationManagerDelegate {
    var host: () -> HostClient? = { nil }
    private let problem: (String?) -> Void
    private let manager = CLLocationManager()
    private var throttle = LocationThrottle()
    private var running = false

    init(problem: @escaping (String?) -> Void) {
        self.problem = problem
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
    }

    func setRunning(_ run: Bool) {
        guard run != running else { return }
        running = run
        if run {
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: problem(nil); manager.startUpdatingLocation()
            default: problem("Allow Caboose to use your location in Settings to share it with the computer.")
            }
        } else {
            manager.stopUpdatingLocation()
            throttle.reset()
        }
    }

    /// The owner turned sharing off: the computer forgets the location.
    func stopSharing() {
        setRunning(false)
        problem(nil)
        guard let host = host() else { return }
        Task { try? await host.deleteLocation() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.running else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: self.problem(nil); manager.startUpdatingLocation()
            case .notDetermined: break
            default: self.problem("Allow Caboose to use your location in Settings to share it with the computer.")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last, last.horizontalAccuracy >= 0 else { return }
        let fix = LocationThrottle.Fix(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, accuracy: last.horizontalAccuracy)
        let altitude = last.verticalAccuracy >= 0 ? last.altitude : nil
        Task { @MainActor in
            guard self.running, self.throttle.admit(fix, at: Date().timeIntervalSince1970), let host = self.host() else { return }
            try? await host.putLocation(latitude: fix.latitude, longitude: fix.longitude, accuracy: min(fix.accuracy, 100_000),
                                        altitude: altitude.map { min(100_000, max(-1000, $0)) })
        }
    }
}
