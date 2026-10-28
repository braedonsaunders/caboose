import Foundation
import Observation

/// A video playing in the computer's browser, as the host reports it (`media.playing`).
struct PlayingMedia: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var page: String
    var title: String
    /// A direct http(s) source; absent for YouTube, which plays from `videoId`.
    var src: String?
    /// "youtube", "hls" or "video".
    var kind: String
    var videoId: String?
    var position: Double
    var duration: Double?
    var paused: Bool

    /// Whether the phone can play it itself.
    var playable: Bool {
        switch kind {
        case "youtube": videoId?.isEmpty == false
        case "hls", "video": src.flatMap(URL.init(string:)).map { ["http", "https"].contains($0.scheme?.lowercased()) } ?? false
        default: false
        }
    }

    var displayTitle: String { title.isEmpty ? (URL(string: page)?.host() ?? "Video") : title }
}

/// Moves a video from the computer's browser to the phone (or AirPlay) and back: the Linux
/// copy pauses while the phone plays and continues at the phone's time afterwards.
@MainActor @Observable
final class MediaHandoff {
    private(set) var playing: PlayingMedia?
    /// Being played on the phone now.
    private(set) var handedOff: PlayingMedia?
    /// Handed to another app (the YouTube app), so the time it stopped at is unknown.
    private(set) var awaitingReturn: PlayingMedia?
    private var dismissedID: String?
    private var host: () -> HostClient? = { nil }

    func attach(host: @escaping () -> HostClient?) {
        self.host = host
        Task { await refresh() }
    }

    func reset() {
        playing = nil
        handedOff = nil
        awaitingReturn = nil
        dismissedID = nil
    }

    /// Offered while the computer plays something the phone can take, and it is not already here.
    var offer: PlayingMedia? {
        guard let playing, playing.playable, !playing.paused, playing.id != dismissedID,
              handedOff == nil, awaitingReturn == nil else { return nil }
        return playing
    }

    func dismissOffer() { dismissedID = playing?.id }

    func refresh() async {
        struct Current: Decodable { var media: PlayingMedia? }
        guard let host = host(), let current: Current = try? await host.request("GET", "/v1/media", timeout: 15) else { return }
        playing = current.media
    }

    /// Control-socket events; returns whether this was one of ours.
    @discardableResult
    func handle(_ type: String, _ event: [String: Any]) -> Bool {
        switch type {
        case "media.playing":
            guard let object = event["media"],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let media = try? JSONDecoder().decode(PlayingMedia.self, from: data) else { return true }
            if media.id != playing?.id { dismissedID = nil }
            playing = media
        case "media.stopped":
            if let id = event["id"] as? String, playing?.id == id { playing = nil }
        default:
            return false
        }
        return true
    }

    /// Pauses the computer's copy and plays it here.
    func playHere(_ media: PlayingMedia) async {
        await control(media.id, "pause", position: nil)
        handedOff = media
    }

    /// The phone stopped at `position`: the computer continues from there.
    func finished(at position: Double?) async {
        guard let media = handedOff else { return }
        handedOff = nil
        await control(media.id, "play", position: position)
    }

    /// The embedded player refused the video: play it in the YouTube app instead, and offer
    /// to continue on the computer when Caboose is back.
    func handToYouTubeApp(at position: Double) -> URL? {
        guard let media = handedOff, let id = media.videoId else { return nil }
        handedOff = nil
        awaitingReturn = media
        return URL(string: "https://www.youtube.com/watch?v=\(id)&t=\(Int(position))s")
    }

    func resumeOnComputer() async {
        guard let media = awaitingReturn else { return }
        awaitingReturn = nil
        await control(media.id, "play", position: nil)
    }

    func stayOnPhone() { awaitingReturn = nil }

    private func control(_ id: String, _ action: String, position: Double?) async {
        guard let host = host() else { return }
        var body: [String: JSONValue] = ["action": .string(action)]
        if let position, position.isFinite { body["position"] = .double(max(0, position)) }
        guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return }
        let path = "/v1/media/\(id)/control"
        let _: [String: Bool]? = try? await host.request("POST", path, body: body, timeout: 20)
    }
}
