import CabooseKit
import CoreLocation
import ImageIO
import MediaPlayer
import UIKit

/// The computer's media in the system's Now Playing: Control Center, the Lock Screen,
/// AirPods and keyboard media keys control the Linux player. It publishes metadata and
/// handles commands only while it shows a track and is not suspended; the app's audio
/// session is configured where the sound plays.
@MainActor
final class NowPlayingCenter {
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended { release() } else if let shown { publish(shown.state) }
        }
    }
    /// The track shown and the host it came from: commands go to that computer only.
    private var shown: (state: BridgeNowPlaying, host: HostClient)?
    private var artwork: (url: URL, image: MPMediaItemArtwork)?
    private let loader = ArtworkLoader()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var published = false

    func show(_ state: BridgeNowPlaying, host: HostClient) {
        shown = (state, host)
        guard !suspended else { return }
        publish(state)
    }

    func stopped(_ id: String) {
        guard shown?.state.id == id else { return }
        clear()
    }

    func clear() {
        shown = nil
        artwork = nil
        loader.cancel()
        release()
    }

    /// Gives Now Playing back: our metadata and command handlers go; other players' stay.
    private func release() {
        let commands = MPRemoteCommandCenter.shared()
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        if published {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            for command in [commands.playCommand, commands.pauseCommand, commands.togglePlayPauseCommand, commands.nextTrackCommand,
                            commands.previousTrackCommand, commands.changePlaybackPositionCommand] { command.isEnabled = false }
            published = false
        }
    }

    private func publish(_ state: BridgeNowPlaying) {
        register()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: state.title.isEmpty ? state.player : state.title,
            MPMediaItemPropertyArtist: state.artist.isEmpty ? state.player : state.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.position(at: Date().timeIntervalSince1970 * 1000),
            MPNowPlayingInfoPropertyPlaybackRate: state.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !state.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = state.album }
        if let duration = state.duration { info[MPMediaItemPropertyPlaybackDuration] = duration } else { info[MPNowPlayingInfoPropertyIsLiveStream] = true }
        if let artwork, artwork.url == state.artwork { info[MPMediaItemPropertyArtwork] = artwork.image }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.paused ? .paused : .playing
        published = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = state.canPlay
        commands.pauseCommand.isEnabled = state.canPause
        commands.togglePlayPauseCommand.isEnabled = state.canPlay || state.canPause
        commands.nextTrackCommand.isEnabled = state.canNext
        commands.previousTrackCommand.isEnabled = state.canPrevious
        commands.changePlaybackPositionCommand.isEnabled = state.canSeek && state.duration != nil
        if let url = state.artwork, artwork?.url != url {
            loader.load(url) { [weak self] image in
                guard let self, let image, self.shown?.state.artwork == url else { return }
                self.artwork = (url, MPMediaItemArtwork(boundsSize: image.size) { _ in image })
                if !self.suspended, let shown = self.shown { self.publish(shown.state) }
            }
        }
    }

    private func register() {
        guard targets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        let send = { [weak self] (action: String, position: Double?) -> MPRemoteCommandHandlerStatus in
            // The track and computer shown now; a command never reaches another computer.
            guard let self, !self.suspended, let (state, host) = self.shown else { return .noActionableNowPlayingItem }
            Task { try? await host.nowPlayingControl(state.id, action: action, position: position) }
            return .success
        }
        let simple: [(MPRemoteCommand, String)] = [
            (commands.playCommand, "play"), (commands.pauseCommand, "pause"), (commands.togglePlayPauseCommand, "toggle"),
            (commands.nextTrackCommand, "next"), (commands.previousTrackCommand, "previous"),
        ]
        for (command, action) in simple { targets.append((command, command.addTarget { _ in send(action, nil) })) }
        let seek = commands.changePlaybackPositionCommand
        targets.append((seek, seek.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return send("seek", max(0, event.positionTime))
        }))
    }
}

/// Fetches a track's artwork from the URL the computer's player names: untrusted, so one
/// request at a time, no cookies or cache, no redirects, at most 2 MiB, images only.
@MainActor
private final class ArtworkLoader {
    static let limit = 2 * 1024 * 1024
    private var task: Task<Void, Never>?
    private var loading: URL?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    func load(_ url: URL, done: @escaping (UIImage?) -> Void) {
        guard loading != url else { return }
        cancel()
        loading = url
        task = Task { [session] in
            let image = await Self.fetch(url, session: session)
            guard !Task.isCancelled else { return }
            self.loading = nil
            done(image)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        loading = nil
    }

    private nonisolated static func fetch(_ url: URL, session: URLSession) async -> UIImage? {
        guard url.scheme == "https", let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        // Every exit, the cap included, ends the transfer.
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true, http.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        return thumbnail(data)
    }

    /// At most 512 pixels on a side, decoded only at that size: a small file can name huge
    /// dimensions.
    private nonisolated static func thumbnail(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 512,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// The phone's location for one computer's GeoClue, while the owner shares it with that
/// computer and Caboose is in front and connected. A fix or an authorization answer that
/// arrives after `stop` goes nowhere.
@MainActor
final class LocationSharing: NSObject, CLLocationManagerDelegate {
    private let problem: (String?) -> Void
    private let manager = CLLocationManager()
    private var throttle = LocationThrottle()
    private var target: (computer: String, host: HostClient)?

    init(problem: @escaping (String?) -> Void) {
        self.problem = problem
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
    }

    func start(for computer: String, host: HostClient) {
        guard target?.computer != computer || target?.host.baseURL != host.baseURL else { return }
        stop()
        target = (computer, host)
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: problem(nil); manager.startUpdatingLocation()
        default: problem("Allow Caboose to use your location in Settings to share it with the computer.")
        }
    }

    func stop() {
        target = nil
        manager.stopUpdatingLocation()
        throttle.reset()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.target != nil else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.problem(nil); self.manager.startUpdatingLocation()
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
            // Only to the computer sharing is on for now.
            guard let (_, host) = self.target, self.throttle.admit(fix, at: Date().timeIntervalSince1970) else { return }
            try? await host.putLocation(latitude: fix.latitude, longitude: fix.longitude, accuracy: min(fix.accuracy, 100_000),
                                        altitude: altitude.map { min(100_000, max(-1000, $0)) })
        }
    }
}
