#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// The live game of a window (docs/game-handoff.md, "The client"): a `WKWebView` that loads
/// `caboose-game://<id>/<entry>` once the game's saves are down from the computer.
///
/// There is one per game, kept on its `RemoteGame`: whichever `RemoteWindowView` runs the
/// window's game lays it over the window's picture, so moving between views never restarts
/// the game. The web view has its own, non-persistent website data, so the computer is the
/// only place the game's state lives. Touch, keys, the pointer and game controllers go to the
/// page. When the view leaves the screen (or the app stops being active) a snapshot of the
/// game becomes the window's picture, for Home and the window strip.
@MainActor
final class GameSurfaceView: UIView, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private(set) weak var game: RemoteGame?
    let webView: WKWebView
    private let handler: CabooseGameSchemeHandler
    private let saves: GameSaveSync
    private let content: WKUserContentController
    private let message = UILabel()
    private let progress = UIActivityIndicatorView(style: .large)
    private var loading: Task<Void, Never>?
    private var resignObserver: NSObjectProtocol?

    /// The game's surface, made the first time it is asked for.
    static func surface(for game: RemoteGame) -> GameSurfaceView {
        if let surface = game.surface as? GameSurfaceView { return surface }
        let surface = GameSurfaceView(game: game)
        game.surface = surface
        return surface
    }

    private init(game: RemoteGame) {
        self.game = game
        handler = CabooseGameSchemeHandler(game: game)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        saves = GameSaveSync(saves: game.descriptor.saves, device: device, host: { [weak game] in game?.host })
        content = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: CabooseGameScheme.name)
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
        game.onEnd { [weak self] in self?.end() }
        resignObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.window != nil { self?.capturePicture() } }
        }
        load()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
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

    /// Brings the saves down, then loads the page with them.
    private func load() {
        loading?.cancel()
        message.isHidden = true
        progress.startAnimating()
        loading = Task { [weak self] in
            guard let self else { return }
            do {
                let seed = try await saves.load()
                guard !Task.isCancelled, let game, !game.isEnded, let url = game.entryURL else { return }
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

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The page cannot leave the game: other schemes are only loaded inside frames.
        let url = navigationAction.request.url
        let isGame = url?.scheme == CabooseGameScheme.name || (url == Self.blank && game?.isEnded != false)
        return isGame || navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            show("The game's page could not be loaded from the computer (\(response.statusCode)).")
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled { return }
        show("The game could not be loaded. \(error.localizedDescription)")
    }

    /// WebKit ended the page (memory pressure, for one): start again from the saves written so far.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { [weak self] in
            await self?.saves.flush()
            self?.load()
        }
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
            let reason = (body["message"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            show("The game stopped\(reason). Its page is not cross-origin isolated, so games that use threads cannot run in it.")
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
        guard let game, !game.isEnded, webView.url != nil, bounds.width > 0, bounds.height > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak game] image, _ in
            guard let image = image?.cgImage else { return }
            MainActor.assumeIsolated { game?.seedPicture(image) }
        }
    }

    private static let blank = URL(string: "about:blank")!

    /// The game ended: the page stops at once, and the saves it wrote still go to the computer.
    private func end() {
        loading?.cancel()
        handler.invalidate()
        webView.stopLoading()
        // The blank page ends the game's scripts and sound now, not when the view goes.
        webView.load(URLRequest(url: Self.blank))
        content.removeAllUserScripts()
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
