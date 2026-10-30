import Foundation

/// Agent-app pages kept running on the device after their display connection closed.
///
/// When Caboose leaves the screen its display connection closes, and with it every app that
/// runs natively on the device. A page that is playing media (audio, a video in Picture in
/// Picture, Web Audio) is kept instead, so the sound goes on in the background with the
/// system's media controls, and so do its timers and its `net` requests, which go from the
/// device. Its computer bridge is disconnected meanwhile. When the computer announces the same
/// app again, the kept page takes its place without reloading; once the computer has announced
/// its apps and that one is not among them, the page ends. A page that is not playing ends at
/// once, as before.
@MainActor
public final class AgentAppPages {
    public static let shared = AgentAppPages()

    struct Key: Hashable {
        var computer: String
        var app: String
    }

    private struct Kept {
        let key: Key
        let page: AnyObject
        let adopt: (RemoteGame) -> Bool
        let end: () -> Void
    }

    /// At most this many pages are kept; the oldest ends first.
    static let limit = 4
    private var kept: [Kept] = []
    /// Pages that end while this is set are kept rather than stopped.
    private(set) var isParking = false

    /// The pages kept now.
    var count: Int { kept.count }

    /// Runs `body`, which closes the display connection because the app is leaving the
    /// screen; app pages it ends are kept while they play.
    public func parking(_ body: () -> Void) {
        isParking = true
        defer { isParking = false }
        body()
    }

    static func key(of game: RemoteGame) -> Key? {
        guard let app = game.webview?.app, let computer = game.host?.webviewComputerKey else { return nil }
        return Key(computer: computer, app: app)
    }

    /// Keeps `page`, which `adopt` gives to the app's next announcement and `end` stops.
    func keep(_ key: Key, page: AnyObject, adopt: @escaping (RemoteGame) -> Bool, end: @escaping () -> Void) {
        self.end(key: key)
        kept.append(Kept(key: key, page: page, adopt: adopt, end: end))
        while kept.count > Self.limit { kept.removeFirst().end() }
    }

    /// The computer announced `game`: a page kept for the same app on the same computer becomes
    /// its page. Returns whether one did.
    @discardableResult
    func adopt(_ game: RemoteGame) -> Bool {
        guard let key = Self.key(of: game), let index = kept.firstIndex(where: { $0.key == key }) else { return false }
        let page = kept.remove(at: index)
        if page.adopt(game) { return true }
        page.end()
        return false
    }

    /// Ends `page` if it is kept.
    func end(page: AnyObject) {
        guard let index = kept.firstIndex(where: { $0.page === page }) else { return }
        kept.remove(at: index).end()
    }

    private func end(key: Key) {
        guard let index = kept.firstIndex(where: { $0.key == key }) else { return }
        kept.remove(at: index).end()
    }

    /// `computer` has announced every app it runs here: kept pages of others end.
    func settled(computer: String) {
        let ending = kept.filter { $0.key.computer == computer }
        kept.removeAll { $0.key.computer == computer }
        for page in ending { page.end() }
    }

    /// Ends every kept page (signing out, forgetting a computer).
    public func endAll() {
        let ending = kept
        kept.removeAll()
        for page in ending { page.end() }
    }
}
