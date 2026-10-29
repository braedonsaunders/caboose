#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// The live game of a window (docs/game-handoff.md, "The client"): a `WKWebView` that loads
/// `http://127.0.0.1:<port>/<token>/<entry>` from the game's own `GameServer` once the game's
/// saves are down from the computer.
///
/// There is one per game, kept on its `RemoteGame`: whichever `RemoteWindowView` runs the
/// window's game lays it over the window's picture, so moving between views never restarts
/// the game. The web view has its own, non-persistent website data, so the computer is the
/// only place the game's state lives, and it navigates nowhere but the game's origin. Touch,
/// keys, the pointer and game controllers go to the page. When the view leaves the screen (or
/// the app stops being active) a snapshot of the game becomes the window's picture, for Home
/// and the window strip.
///
/// A page that cannot run here (it stops on an error while not cross-origin isolated, WebKit
/// ends it twice within a minute, or its server cannot start) declines the game
/// (`RemoteGame.decline`): the page stops, and the surface says the computer runs the game
/// instead.
@MainActor
final class GameSurfaceView: UIView, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private(set) weak var game: RemoteGame?
    let webView: WKWebView
    private let server: GameServer
    /// The origin the page was loaded from, once it was.
    private var origin: GameOrigin?
    private let saves: GameSaveSync
    private let content: WKUserContentController
    private let message = UILabel()
    private let progress = UIActivityIndicatorView(style: .large)
    private var loading: Task<Void, Never>?
    private var terminations = GameTerminations()
    private var observers: [NSObjectProtocol] = []

    /// The game's surface, made the first time it is asked for.
    static func surface(for game: RemoteGame) -> GameSurfaceView {
        if let surface = game.surface as? GameSurfaceView { return surface }
        let surface = GameSurfaceView(game: game)
        game.surface = surface
        return surface
    }

    private init(game: RemoteGame) {
        self.game = game
        server = GameServer(root: game.descriptor.root, responder: GameFileResponder(source: { [weak game] in
            game?.host.map { GameFileClient(host: $0) }
        }))
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        saves = GameSaveSync(saves: game.descriptor.saves, device: device, host: { [weak game] in game?.host })
        content = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = content
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        backgroundColor = .black
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true
        #endif
        // A touch on the game gives it the keyboard; the touch itself goes on to the page.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        content.addScriptMessageHandler(GameMessages(self), contentWorld: .page, name: GameFSScript.handlerName)
        addSubview(webView)
        progress.color = .white
        progress.hidesWhenStopped = true
        addSubview(progress)
        message.textColor = .white
        message.backgroundColor = UIColor(white: 0, alpha: 0.85)
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textAlignment = .center
        message.numberOfLines = 0
        message.isHidden = true
        addSubview(message)
        game.savesFlusher = { [weak saves] in await saves?.flush() }
        game.gamepadSink = { [weak self] state in self?.send(gamepad: state) }
        game.stateSink = { [weak self] in self?.showState() }
        game.onEnd { [weak self] in self?.end() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window != nil { self?.capturePicture() } }
        })
        // The system can take the server's socket back while the app is suspended.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.listenAgain() }
        })
        load()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        webView.frame = bounds
        progress.center = CGPoint(x: bounds.midX, y: bounds.midY)
        message.frame = bounds
    }

    /// Gives the page the keyboard, and with it hardware keys and game controllers.
    @discardableResult
    func focus() -> Bool { webView.becomeFirstResponder() }

    /// The web view's content, not the web view, holds the keyboard; asking again keeps it.
    @objc private func tapped() { focus() }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil, window != nil { capturePicture() }
    }

    // MARK: Loading

    /// Starts the game's origin and brings the saves down, then loads the page with them.
    private func load() {
        loading?.cancel()
        message.isHidden = true
        progress.startAnimating()
        loading = Task { [weak self] in
            guard let self else { return }
            let origin: GameOrigin
            do {
                origin = try await server.start()
            } catch {
                guard !Task.isCancelled else { return }
                return decline(GameDecline.notServed(error))
            }
            do {
                let seed = try await saves.load()
                guard !Task.isCancelled, let game, !game.isEnded, game.state == .running,
                      let url = origin.url(game.descriptor.entry) else { return }
                self.origin = origin
                content.removeAllUserScripts()
                content.addUserScript(WKUserScript(source: GameFSScript.source(seed: seed), injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: true, in: .page))
                content.addUserScript(WKUserScript(source: GameGamepadScript.source, injectionTime: .atDocumentStart,
                                                   forMainFrameOnly: true, in: .page))
                webView.load(URLRequest(url: url))
            } catch {
                guard !Task.isCancelled else { return }
                show("The game's saves could not be read from the computer. \(error.localizedDescription)")
            }
        }
    }

    /// Covers the game with what went wrong.
    func show(_ text: String) {
        progress.stopAnimating()
        message.text = text
        message.isHidden = false
    }

    /// Whether the game is still this device's to run.
    private var isRunning: Bool { game.map { !$0.isEnded && $0.state == .running } ?? false }

    /// The server went down while the app was suspended: it listens on its port again.
    private func listenAgain() {
        guard origin != nil, isRunning else { return }
        Task { [server] in _ = try? await server.start() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The page goes nowhere but the game's origin, in a frame or not; a link elsewhere opens
        // nothing. A frame may be blank, and so may the page once the game has stopped.
        guard let url = navigationAction.request.url, navigationAction.targetFrame != nil else { return .cancel }
        if let origin, origin.contains(url) { return .allow }
        guard url.scheme == "about", url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" else { return .cancel }
        return !isRunning || navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, isRunning, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            show("The game's page could not be loaded from the computer (\(response.statusCode)).")
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isRunning else { return }
        progress.stopAnimating()
        if let gamepad = game?.gamepad { send(gamepad: gamepad) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        if !isRunning || (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled { return }
        show("The game could not be loaded. \(error.localizedDescription)")
    }

    /// WebKit ended the page (memory pressure, for one): start again from the saves written so
    /// far. A second time within a minute, the device cannot run the game.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard isRunning else { return }
        if terminations.record(Date()) { return decline(GameDecline.terminatedTwice) }
        Task { [weak self] in
            await self?.saves.flush()
            guard let self, self.isRunning else { return }
            self.load()
        }
    }

    // MARK: Declining

    /// The page cannot run here: it stops, and the game goes back to the computer.
    private func decline(_ reason: String) {
        guard let game, !game.isEnded, game.state == .running else { return }
        game.decline(reason)
        stopPage()
    }

    /// Says where a declined game is.
    private func showState() {
        switch game?.state {
        case .declined:
            show("Running this game on the computer instead…")
        case .declineUnanswered:
            show("This game cannot run on this device, and the computer did not take it back. Close the window.")
        case .running, nil:
            break
        }
    }

    /// The page and its origin stop; the saves it wrote still go to the computer.
    private func stopPage() {
        loading?.cancel()
        server.stop()
        webView.stopLoading()
        // The blank page ends the game's scripts and sound now.
        webView.load(URLRequest(url: Self.blank))
        content.removeAllUserScripts()
    }

    // MARK: The page

    fileprivate func received(_ body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "changes":
            guard let mount = body["mount"] as? String, let list = body["changes"] as? [[String: Any]],
                  saves.saves.contains(where: { $0.mount == mount }) else { return }
            saves.record(GameSaveSync.changes(list, mount: mount))
        case "isolation":
            decline(GameDecline.notIsolated(body["message"] as? String ?? ""))
        case "failure":
            show(body["message"] as? String ?? "The game's saves could not be connected.")
        default:
            break
        }
    }

    /// The on-screen controller's state, to the page's `window.cabooseGamepad` (nil disconnects it).
    private func send(gamepad state: GameGamepadState?) {
        guard webView.url != nil else { return }
        let call = GameGamepadScript.call(state)
        webView.callAsyncJavaScript(call.body, arguments: call.arguments, in: nil, in: .page, completionHandler: nil)
    }

    // MARK: Picture and end

    /// A snapshot of the game becomes the window's picture.
    private func capturePicture() {
        guard let game, isRunning, webView.url != nil, bounds.width > 0, bounds.height > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak game] image, _ in
            guard let image = image?.cgImage else { return }
            MainActor.assumeIsolated { game?.seedPicture(image) }
        }
    }

    private static let blank = URL(string: "about:blank")!

    /// The game ended: the page and its origin stop at once, and the saves it wrote still go to the computer.
    private func end() {
        stopPage()
        content.removeAllScriptMessageHandlers()
        removeFromSuperview()
        game?.surface = nil
        let saves = saves
        Task { await saves.finish() }
    }
}

/// The page's `cabooseFS` messages, held weakly: the content controller keeps its handlers.
@MainActor
private final class GameMessages: NSObject, WKScriptMessageHandlerWithReply {
    weak var surface: GameSurfaceView?
    init(_ surface: GameSurfaceView) { self.surface = surface }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        surface?.received(message.body)
        return (nil, nil)
    }
}
#endif
