import CoreGraphics
import CryptoKit
import Foundation

/// How a game surface reaches the computer's files: the host's HTTP base and bearer token,
/// derived from the display connection the session was made with.
public struct GameHostAccess: Equatable, Sendable {
    /// `https://host[:port][/prefix]`, without a trailing slash.
    public var baseURL: URL
    public var token: String
    /// Names this computer in the game cache: a digest of the token, which only this
    /// computer's routes accept, so it stays the same over every address the host has.
    public var computerKey: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        computerKey = SHA256.hash(data: Data("caboose-game-cache\u{0}\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The host behind a display WebSocket: `wss` → `https`, `ws` → `http`, and the path up to
    /// its `/v1/` route dropped (a prefix the host is served under stays). Nil for any other scheme.
    public init?(displayURL: URL, token: String) {
        guard var components = URLComponents(url: displayURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss", "https": components.scheme = "https"
        case "ws", "http": components.scheme = "http"
        default: return nil
        }
        let path = components.path
        let prefix = path.range(of: "/v1/", options: .backwards).map { String(path[..<$0.lowerBound]) } ?? ""
        components.path = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        self.init(baseURL: url, token: token)
    }

    /// `<base>/v1/fs/<operation>?path=<path>`.
    public func fileURL(_ operation: String, path: String) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/fs/" + operation), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return components.url!
    }

    /// An authorized request for a `/v1/fs` route.
    public func request(_ operation: String, path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: fileURL(operation, path: path), timeoutInterval: 60)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

/// A game handed off to this device (`game.create`): it runs in a web view laid over its
/// window, which keeps its place, chrome and lifecycle on the computer.
///
/// The session makes one when the server announces the game, keeps it through a resume from
/// the same server epoch, and ends it when the server destroys it, the window goes, or the
/// session ends. The UI keeps its live surface here, so one web view runs the game however
/// many views show the window.
@MainActor
public final class RemoteGame: Identifiable {
    public nonisolated let id: Int
    public let descriptor: GameDescriptor
    /// Where the game's files are; replaced when the session resumes through another address.
    public internal(set) var host: GameHostAccess?
    public private(set) var isEnded = false
    /// The window's picture, which a snapshot of the game seeds for Home and the window strip.
    let picture: WindowSurface
    /// The UI's live surface for this game, if one was made.
    var surface: AnyObject?
    /// Writes the saves still waiting to go to the computer.
    var savesFlusher: (() async -> Void)?
    /// An on-screen controller the page sees through its Gamepad API (`GameGamepadState`);
    /// nil while none is showing. Set it on every change; the page gets each new state at once.
    public var gamepad: GameGamepadState? {
        didSet { if gamepad != oldValue { gamepadSink?(gamepad) } }
    }
    /// Hands `gamepad` to the live page.
    var gamepadSink: ((GameGamepadState?) -> Void)?
    private var endHandlers: [() -> Void] = []

    /// Whether this build can run games: UIKit with WebKit.
    public nonisolated static var isSupported: Bool {
        #if canImport(UIKit) && canImport(WebKit)
        return true
        #else
        return false
        #endif
    }

    init(_ descriptor: GameDescriptor, host: GameHostAccess?, picture: WindowSurface) {
        id = descriptor.id
        self.descriptor = descriptor
        self.host = host
        self.picture = picture
    }

    /// `caboose-game://<id>/<entry>`.
    public var entryURL: URL? {
        var components = URLComponents()
        components.scheme = CabooseGameScheme.name
        components.host = String(id)
        components.path = "/" + descriptor.entry.split(separator: "/").joined(separator: "/")
        return components.url
    }

    /// Runs `body` once the game ends (at once if it already has).
    func onEnd(_ body: @escaping () -> Void) {
        if isEnded { body() } else { endHandlers.append(body) }
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        let handlers = endHandlers
        endHandlers.removeAll()
        savesFlusher = nil
        gamepadSink = nil
        for handler in handlers { handler() }
    }

    /// Waits, for at most `seconds`, for the saves still waiting to go to the computer. The
    /// writes carry on after a timeout; only the wait ends.
    public func flushSaves(within seconds: Double) async {
        guard let flusher = savesFlusher else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce(continuation)
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                once.resume()
            }
            Task { @MainActor in
                await flusher()
                timeout.cancel()
                once.resume()
            }
        }
    }

    /// Paints a snapshot of the game over the whole window picture.
    func seedPicture(_ image: CGImage) {
        guard !isEnded, picture.pixelSize.width > 0, picture.pixelSize.height > 0 else { return }
        picture.upload(image: image, into: CGRect(origin: .zero, size: picture.pixelSize))
    }
}

/// The URL scheme game pages load from.
public enum CabooseGameScheme {
    public static let name = "caboose-game"
}

/// Resumes a continuation the first time it is asked to.
@MainActor
private final class ResumeOnce {
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
