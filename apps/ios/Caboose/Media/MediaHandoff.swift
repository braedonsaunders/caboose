import Foundation
import Observation

/// A video playing in the computer's browser, as the host reports it (`media.playing`).
struct PlayingMedia: Decodable, Equatable, Identifiable, Sendable {
    var id: String
    var page: String
    var title: String
    /// The video's own http(s) source, for "hls" and "video"; absent for "page".
    var src: String?
    /// "hls" or "video" play from `src`; "page" (a stream the page builds itself) opens the page.
    var kind: String
    var position: Double
    var duration: Double?
    var paused: Bool

    var sourceURL: URL? { src.flatMap(URL.init(string:)).flatMap(Self.web) }
    var pageURL: URL? { URL(string: page).flatMap(Self.web) }

    /// Whether the phone can take it: its source, or for a page-built stream, its page.
    var playable: Bool { kind == "page" ? pageURL != nil : sourceURL != nil }

    var displayTitle: String { title.isEmpty ? (pageURL?.host() ?? "Video") : title }

    private static func web(_ url: URL) -> URL? { ["http", "https"].contains(url.scheme?.lowercased()) ? url : nil }
}

/// "Play on iPhone / Apple TV", an action the owner takes from a window's menu. Video
/// itself reaches the phone like every window does; this moves one video off the computer:
/// the Linux copy pauses while the phone plays and continues at the phone's time afterwards.
@MainActor @Observable
final class MediaHandoff {
    private(set) var playing: PlayingMedia?
    /// Being played on the phone now.
    private(set) var handedOff: PlayingMedia? {
        didSet { onHandoffChanged?(handedOff != nil) }
    }
    /// Native playback owns Now Playing until it returns to the computer.
    var onHandoffChanged: ((Bool) -> Void)?
    private var host: () -> HostClient? = { nil }

    func attach(host: @escaping () -> HostClient?) {
        self.host = host
        Task { await refresh() }
    }

    func reset() {
        playing = nil
        handedOff = nil
    }

    /// What the window menu offers to move to the phone, if anything.
    var available: PlayingMedia? {
        guard let playing, playing.playable, handedOff == nil else { return nil }
        return playing
    }

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

    private func control(_ id: String, _ action: String, position: Double?) async {
        guard let host = host() else { return }
        var body: [String: JSONValue] = ["action": .string(action)]
        if let position, position.isFinite { body["position"] = .double(max(0, position)) }
        guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return }
        let path = "/v1/media/\(id)/control"
        let _: [String: Bool]? = try? await host.request("POST", path, body: body, timeout: 20)
    }
}
