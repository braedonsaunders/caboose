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
/// keys, the pointer and game controllers go to the page, and so does the input of the app's
/// own controls (a trackpad, its keyboard) aimed at the window, as DOM events (`GameInput`). When the view leaves the screen (or
/// the app stops being active) a snapshot of the game becomes the window's picture, for Home
/// and the window strip.
///
/// A page that cannot run here (it stops on an error while not cross-origin isolated, WebKit
/// ends it twice within a minute, or its server cannot start) declines the game
/// (`RemoteGame.decline`): the page stops, and the surface says the computer runs the game
/// instead.
@MainActor
final class GameSurfaceView: UIView, WKNavigationDelegate, UIGestureRecognizerDelegate {
    private(set) weak var game: RemoteGame? {
        didSet { current.game = game }
    }
    /// The game the file service and saves are reached through, which a kept page's next game replaces.
    private let current: CurrentGame
    let webView: WKWebView
    private let server: GameServer
    private let hasStableOrigin: Bool
    /// The origin the page was loaded from, once it was.
    private var origin: GameOrigin?
    private let saves: GameSaveSync
    private var appBridge: AgentAppBridge?
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
        let current = CurrentGame(game)
        self.current = current
        self.game = game
        let stable = game.webview.flatMap { app in game.host.flatMap { WebviewOriginStore().origin(computer: $0.webviewComputerKey, app: app.app) } }
        hasStableOrigin = game.webview == nil || stable != nil
        server = GameServer(root: game.descriptor.root, responder: GameFileResponder(directoryIndex: game.webview != nil, source: { [current] in
            current.game?.host.map { GameFileClient(host: $0) }
        }), token: stable?.token ?? GameOrigin.newToken(), appPolicy: game.webview != nil,
            appEntry: game.webview?.entry, preferredPort: stable?.port)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        saves = GameSaveSync(saves: game.descriptor.saves, device: device, host: { [current] in current.game?.host })
        content = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = game.webview == nil ? .nonPersistent() : .default()
        configuration.userContentController = content
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        backgroundColor = .black
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = game.webview != nil
        webView.scrollView.bounces = game.webview != nil
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
        if game.webview == nil {
            content.addScriptMessageHandler(GameMessages(self), contentWorld: .page, name: GameFSScript.handlerName)
        }
        if game.webview != nil {
            let bridge = AgentAppBridge(game: game, webView: webView)
            appBridge = bridge
            bridge.onFailure = { [weak self] in self?.decline("The app bridge disconnected") }
            bridge.onReload = { [weak self] in self?.load() }
            content.addScriptMessageHandler(bridge, contentWorld: AgentAppBridge.world, name: "caboose")
        }
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
        attach(game)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Keys and buttons held when the app leaves the screen are not held any more.
                self?.game?.releaseInput()
                if self?.window != nil { self?.capturePicture() }
            }
        })
        // The system can take the server's socket back while the app is suspended.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.listenAgain() }
        })
        load()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Takes `game`'s input, controller, state and end.
    private func attach(_ game: RemoteGame) {
        game.savesFlusher = { [weak saves] in await saves?.flush() }
        game.gamepadSink = { [weak self] state in self?.send(gamepad: state) }
        game.inputSink = { [weak self] events in self?.send(input: events) }
        game.stateSink = { [weak self] in self?.showState() }
        if game.webview != nil { game.resumeSink = { [weak self] in self?.load() } }
        game.onEnd { [weak self] in self?.end() }
    }

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
        if newWindow == nil, window != nil {
            game?.releaseInput()
            capturePicture()
        }
    }

    // MARK: Loading

    /// Starts the game's origin and brings the saves down, then loads the page with them.
    private func load() {
        loading?.cancel()
        guard hasStableOrigin else { return decline("The app could not reserve its origin") }
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
            if let appBridge {
                do {
                    let page = try await appBridge.prepare(origin: origin)
                    let world = try AgentAppBridge.worldScript()
                    guard !Task.isCancelled, let game, !game.isEnded, game.state == .running,
                          let url = origin.url(game.descriptor.entry) else { return }
                    self.origin = origin
                    content.removeAllUserScripts()
                    content.addUserScript(WKUserScript(source: world, injectionTime: .atDocumentStart,
                                                       forMainFrameOnly: true, in: AgentAppBridge.world))
                    content.addUserScript(WKUserScript(source: page, injectionTime: .atDocumentStart,
                                                       forMainFrameOnly: true, in: .page))
                    content.addUserScript(WKUserScript(source: GameInputScript.source, injectionTime: .atDocumentStart,
                                                       forMainFrameOnly: true, in: .page))
                    webView.load(URLRequest(url: url))
                } catch {
                    guard !Task.isCancelled else { return }
                    decline("The app bridge could not be started")
                }
                return
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
                content.addUserScript(WKUserScript(source: GameInputScript.source, injectionTime: .atDocumentStart,
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
        appBridge?.resume()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The page goes nowhere but the game's origin, in a frame or not; a link elsewhere opens
        // nothing. A frame may be blank, and so may the page once the game has stopped.
        guard let url = navigationAction.request.url else { return .cancel }
        if let origin, origin.contains(url), navigationAction.targetFrame != nil { return .allow }
        if game?.webview != nil, navigationAction.navigationType == .linkActivated,
           ["http", "https", "mailto", "tel", "sms"].contains(url.scheme?.lowercased() ?? "") {
            await UIApplication.shared.open(url)
            return .cancel
        }
        guard navigationAction.targetFrame != nil else { return .cancel }
        guard url.scheme == "about", url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc" else { return .cancel }
        return !isRunning || navigationAction.targetFrame?.isMainFrame == false ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, isRunning, let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            if game?.webview != nil { decline("The app page could not be loaded") }
            else { show("The game's page could not be loaded from the computer (\(response.statusCode)).") }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        appBridge?.committed()
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
        if game?.webview != nil { decline("The app page could not be loaded") }
        else { show("The game could not be loaded. \(error.localizedDescription)") }
    }

    /// WebKit ended the page (memory pressure, for one): start again from the saves written so
    /// far. A second time within a minute, the device cannot run the game.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A kept page that WebKit ended has nothing left to carry on.
        guard isRunning else { return AgentAppPages.shared.end(page: self) }
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
            show(game?.webview != nil ? "Running this app on the computer instead…" : "Running this game on the computer instead…")
        case .declineUnanswered:
            show(game?.webview != nil ? "This app cannot run on this device, and the computer did not take it back. Close the window." : "This game cannot run on this device, and the computer did not take it back. Close the window.")
        case .running, nil:
            break
        }
    }

    /// The page and its origin stop; the saves it wrote still go to the computer.
    private func stopPage() {
        appBridge?.end()
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

    /// Input from the app's own controls, to the page's `window.cabooseInput`, in order.
    private func send(input events: [GameInputEvent]) {
        guard webView.url != nil else { return }
        let call = GameInputScript.call(events)
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

    // MARK: Kept pages

    /// The display closed because Caboose left the screen: an app page is kept, and stays kept
    /// if it is playing media (`AgentAppPages`). Returns whether it was kept.
    private func keep() -> Bool {
        guard AgentAppPages.shared.isParking, let game, let key = AgentAppPages.key(of: game),
              game.state == .running, origin != nil, let appBridge else { return false }
        appBridge.park()
        game.releaseInput()
        removeFromSuperview()
        game.surface = nil
        self.game = nil
        AgentAppPages.shared.keep(key, page: self, adopt: { [unowned self] game in self.adopt(game) },
                                  end: { [unowned self] in self.finish() })
        // Only a page that is playing goes on; the system lets the app run for it.
        let task = BackgroundTask()
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                if let self, state != .playing { AgentAppPages.shared.end(page: self) }
                task.end()
            }
        }
        return true
    }

    /// The computer announced this kept page's app again: the page carries on as `game`, and
    /// its bridge reconnects to the computer without a reload.
    private func adopt(_ game: RemoteGame) -> Bool {
        guard game.webview != nil, let appBridge else { return false }
        self.game = game
        game.surface = self
        attach(game)
        appBridge.adopt(game)
        listenAgain()
        return true
    }

    /// The game ended: a page leaving with Caboose may be kept; otherwise it stops.
    private func end() {
        if keep() { return }
        finish()
    }

    /// The page and its origin stop at once, and the saves it wrote still go to the computer.
    private func finish() {
        stopPage()
        content.removeAllScriptMessageHandlers()
        removeFromSuperview()
        game?.surface = nil
        let saves = saves
        Task { await saves.finish() }
    }
}

/// Time to finish a short piece of work after the app leaves the screen.
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Which game a surface serves now, for the closures its file service and saves were made with.
@MainActor
private final class CurrentGame {
    weak var game: RemoteGame?
    init(_ game: RemoteGame) { self.game = game }
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
