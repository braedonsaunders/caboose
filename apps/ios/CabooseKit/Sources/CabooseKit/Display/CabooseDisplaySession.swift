import CoreGraphics
import Foundation
import ImageIO
import Observation
import QuartzCore

/// One connection to caboose-display, the computer's display server, over the Caboose
/// Display Protocol (docs/display.md).
///
/// Every Linux window arrives as its own video stream, decoded in hardware into the
/// `RemoteWindow` and `WindowSurface` the app's views draw. Pictures go straight from the
/// socket's queue to their window's decode queue; everything else is handled on the main
/// actor.
@MainActor @Observable
public final class CabooseDisplaySession: DisplaySession {
    public private(set) var state: DisplaySessionState = .idle
    public private(set) var windows: [Int: RemoteWindow] = [:]
    /// The server's hello: its encoders and features.
    public private(set) var server: ServerHello?
    /// Round trip to the computer, from ping and pong, in milliseconds.
    public private(set) var latencyMs: Double?
    /// The server ended this session for another client (`bye { reason: "replaced" }`).
    public private(set) var isReplaced = false
    /// Why the connection last closed; nil while it has not.
    public private(set) var closeCause: DisplayCloseCause?
    /// Bumped once the server has announced every window it had at a hello, so `windows`
    /// is then exactly the server's. Only a server that sends an `epoch` is counted on for
    /// the order this relies on; against one that does not, it stays put.
    public private(set) var windowsAnnounced = 0
    /// Connections opened so far, counting the first: each resume is one more.
    public private(set) var connections = 0
    /// The epoch of the server's last hello (kept while the connection is lost, until the
    /// next hello replaces it); nil for a server that sends none.
    public var epoch: String? { server?.epoch }
    public var typingEchoMs: Int? { echo.median }

    public var onClipboardText: ((String) -> Void)?
    public var clipboardProvider: (() -> String?)?
    public var onNotification: ((RemoteNotification) -> Void)?
    public var onBell: (() -> Void)?
    public var onRaise: ((Int) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    /// Window ids survive reconnects, so a cached last frame shows until the keyframe lands.
    public var cachedFrame: ((Int) -> CGImage?)?
    /// Whether to ask for the computer's sound (the agent seat, for one, stays silent). Set before `connect()`.
    public var playsAudio = true
    /// Whether to run the games the computer hands off (`wasm` in the hello), where this build
    /// has WebKit to run them in. Set before `connect()`.
    public var runsGames = RemoteGame.isSupported
    /// Whether to render windows from their applications' Vulkan calls (`gpu` in the hello,
    /// docs/gpu-stream.md), where this build has the player. Set before `connect()`.
    public var rendersGPUStreams = RemoteGPUStream.isSupported
    /// The phone's hardware offered to the computer as devices (docs/devices.md), attached
    /// while a connection whose server accepts them is up. Set before `connect()`.
    public var devices: DeviceCenter?
    /// How game surfaces reach the computer's files: the host behind the display URL, with its token.
    public private(set) var gameHost: GameHostAccess?

    /// The pointer's shape by cursor-shape name ("default", "text", …), nil for an image cursor.
    public private(set) var cursorName: String?
    public private(set) var cursorSerial = 0
    /// The focused app's text-input-v3 state, where the server reports it.
    public private(set) var textInput: (window: Int, enabled: Bool, purpose: String?)?
    /// The focused field's text around the caret, as its app last reported it, bumped on each report.
    public private(set) var surroundingText: (window: Int, serial: Int, text: SurroundingText)?

    private var makeStream: () -> ByteStream
    private var displayToken: String
    private var displays: [DisplayInfo]
    private let decoders: [DisplayCodec]
    private let videoDecoders: [DisplayCodec]
    private let makeDecoder: (DisplayCodec) -> PictureDecoder
    private var stream: ByteStream?
    private var incoming: Incoming?
    private var picturesSuspended = false
    /// This connection's windows' decode pipelines; a new connection gets new ones, so nothing
    /// a closed socket still delivers can reach the next.
    private var pipelines = FramePipelineRegistry()
    private var videos = VideoRegistry()
    private var gpuFeeds = GPUStreamFeeds()
    /// This connection's sound, on the clock its video layers share; nil when it plays none.
    private(set) var sound: SoundPlayer?
    private let echo = EchoMeter()
    /// This connection's measurements; a new connection starts with none.
    private var metrics = ConnectionMetrics()
    private var watchdog: LinkWatchdog?
    private var livenessTimer: Timer?
    private var lastPing: CFTimeInterval = 0
    /// Windows kept through a lost connection, with their pictures and the closed pipelines
    /// that last painted them, until the next hello says whether they are still the same.
    private var retained: [Int: FramePipeline] = [:]
    /// After a hello from the same server epoch: the ping whose pong follows every
    /// `window.create` of the hello, and the ids announced so far.
    private var reconciling: (marker: UInt64, announced: Set<Int>)?
    /// The games announced since the last hello; a kept game the burst does not announce has ended.
    private var announcedGames = Set<Int>()
    private var buttons = 0
    private var focusedWindow: Int?
    /// The game that last took input from the app's controls; it releases what it holds when
    /// another window takes the input or the connection goes.
    private weak var gameHoldingInput: RemoteGame?
    /// What the server said about each window: geometry is relative to the parent for
    /// popups and dialogs, so their frames follow the parent.
    private var placement: [Int: (kind: WindowKind, parent: Int?, geometry: CGRect)] = [:]
    /// Geometry the phone asked for and the server has not confirmed yet, with when: updates
    /// still on their way from before it would otherwise snap a dragged window back.
    private var pendingGeometry: [Int: (geometry: CGRect, at: CFTimeInterval, display: DisplayInfo?)] = [:]
    /// The overscan last asked for per window on this connection.
    private var requestedOverscan: [Int: CGSize] = [:]
    /// Each window's last scroll input sequence number this connection (docs/display.md,
    /// "Input sequencing").
    private var scrollSeq: [Int: UInt64] = [:]
    /// Authenticated window output assignment; never inferred from the view's screen.
    private var windowDisplays: [Int: Int] = [:]
    private var lastVsync: [Int: UInt64] = [:]
    private var preedit: (text: String, cursor: (Int, Int))?
    private var lastClipboard: String?

    /// - Parameters:
    ///   - displayURL: the host's `/v1/display` WebSocket.
    ///   - token: the host's bearer token.
    ///   - password: the per-wake display token from `/v1/session`, sent in hello.
    public convenience init(displayURL: URL, token: String, password: String, capabilities: ClientCapabilities?, computerIdentity: String? = nil) {
        self.init(stream: { WebSocketStream(url: displayURL, token: token) }, token: password,
                  displays: capabilities.map { [DisplayInfo($0)] } ?? [], decoders: Self.hardwareDecoders)
        gameHost = GameHostAccess(displayURL: displayURL, token: token, computerIdentity: computerIdentity)
    }

    init(stream: @escaping () -> ByteStream, token: String, displays: [DisplayInfo], decoders: [DisplayCodec],
         videoDecoders: [DisplayCodec] = [], makeDecoder: @escaping (DisplayCodec) -> PictureDecoder = FramePipeline.hardwareDecoder) {
        makeStream = stream
        displayToken = token
        self.displays = displays
        self.decoders = decoders
        self.videoDecoders = videoDecoders
        self.makeDecoder = makeDecoder
    }

    /// What this device decodes in hardware, best first: HEVC, then AV1 where there is an
    /// AV1 decoder, then H.264.
    public nonisolated static var hardwareDecoders: [DisplayCodec] {
        AV1Decoder.isSupported ? [.hevc, .av1, .h264] : [.hevc, .h264]
    }

    private func has(_ feature: String) -> Bool { server?.features.contains(feature) ?? false }

    // MARK: Background

    /// The computer is playing sound: the app keeps this connection in the background for it.
    public var playsSoundNow: Bool { state == .ready && sound?.isPlaying == true }

    /// In the background: pictures are acknowledged without being decoded; sound plays on.
    public func suspendPictures() {
        picturesSuspended = true
        incoming?.setPicturesSuspended(true)
    }

    /// Back in the foreground: every window and video starts again at a keyframe.
    public func resumePictures() {
        guard picturesSuspended else { return }
        picturesSuspended = false
        incoming?.setPicturesSuspended(false)
        for pipeline in pipelines.all { pipeline.resumeAfterGap() }
        for video in videos.all { video.resumeAfterGap() }
    }

    // MARK: Connection

    public func connect() {
        guard state == .idle || isClosed else { return }
        state = .connecting
        connections += 1
        isReplaced = false
        closeCause = nil
        latencyMs = nil
        let stream = makeStream()
        self.stream = stream
        pipelines = FramePipelineRegistry()
        videos = VideoRegistry()
        gpuFeeds = GPUStreamFeeds()
        metrics = ConnectionMetrics()
        let now = CACurrentMediaTime()
        watchdog = LinkWatchdog(openedAt: now)
        lastPing = now
        startLivenessTimer()
        let clock = MediaClock()
        sound = playsAudio ? SoundPlayer(clock: clock) : nil
        picturesSuspended = false
        let incoming = Incoming(pipelines: pipelines, videos: videos, gpuFeeds: gpuFeeds, clock: clock, sound: sound, echo: echo, metrics: metrics,
                                carried: Carried(retained, epoch: server?.epoch),
                                makeDecoder: makeDecoder, retire: { [weak self] id, generation in
            Task { @MainActor in if self?.stream === stream { self?.retireVideo(id, after: generation) } }
        }) { message in
            stream.send(DisplayFraming.encode(message.frame))
        }
        self.incoming = incoming
        let meter = metrics
        stream.open { [weak self] event in
            switch event {
            case .opened:
                Task { @MainActor in if self?.stream === stream { self?.sendHello() } }
            case .data(let data):
                let receivedAt = ProcessInfo.processInfo.systemUptime
                meter.receive(bytes: data.count, at: CACurrentMediaTime())
                do {
                    let others = try incoming.receive(data, receivedAt: receivedAt)
                    if !others.isEmpty { Task { @MainActor in if self?.stream === stream { self?.handle(others) } } }
                } catch {
                    stream.fail(error)
                }
            case .closed(let error):
                Task { @MainActor in if self?.stream === stream { self?.didClose(error) } }
            }
        }
    }

    /// Opens the display again after the connection was lost, through `displayURL` (another
    /// of the host's addresses, perhaps) with the display token from a new `/v1/session`.
    /// The windows stay on screen with their last pictures; the server's hello decides
    /// whether they are still the same windows (see `resume(stream:password:displays:)`).
    public func resume(displayURL: URL, token: String, password: String, capabilities: ClientCapabilities?, computerIdentity: String? = nil) {
        guard isClosed, !isReplaced else { return }
        gameHost = GameHostAccess(displayURL: displayURL, token: token, computerIdentity: computerIdentity ?? gameHost?.webviewComputerKey)
        for window in windows.values { window.game?.host = gameHost }
        resume(stream: { WebSocketStream(url: displayURL, token: token) }, password: password,
               displays: capabilities.map { [DisplayInfo($0)] } ?? [])
    }

    /// Reconnects a closed session. A window keeps its object, its picture and its place
    /// only when the new hello carries the same server `epoch` as the last one, and only
    /// until the hello's `window.create` burst ends without it; otherwise it is removed
    /// before the server's windows arrive, as on a first connection.
    func resume(stream: @escaping () -> ByteStream, password: String, displays: [DisplayInfo]) {
        guard isClosed, !isReplaced else { return }
        makeStream = stream
        displayToken = password
        self.displays = displays
        connect()
    }

    /// Ends the connection for good: nothing is kept for a later resume.
    public func disconnect() {
        stream?.close()
        stream = nil
        close(.local, reason: nil, keepWindows: false)
        closeCause = .local
        dropRetained()
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    /// The socket closed or failed under the session.
    private func didClose(_ error: Error?) {
        let reason = error.map { ($0 as? LocalizedError)?.errorDescription ?? String(describing: $0) }
        close(.transport(reason), reason: reason, keepWindows: true)
    }

    /// The client gives the connection up: the server said goodbye, or it stopped answering.
    private func fail(_ cause: DisplayCloseCause, _ reason: String) {
        stream?.close()
        stream = nil
        close(cause, reason: reason, keepWindows: cause.keepsWindows)
    }

    private func close(_ cause: DisplayCloseCause, reason: String?, keepWindows: Bool) {
        livenessTimer?.invalidate()
        livenessTimer = nil
        watchdog = nil
        if isClosed { return }
        closeCause = cause
        // What a game held from the app's controls is released with the connection, and the
        // phone's hardware stops with it.
        devices?.detach()
        gameHoldingInput?.releaseInput()
        gameHoldingInput = nil
        // State first: an observer that sees windows go while the state is still `.ready`
        // takes it for the window really closing.
        state = .closed(reason: reason)
        tearDown(keepWindows: keepWindows)
    }

    private func tearDown(keepWindows: Bool) {
        let closed = pipelines.removeAll()
        for pipeline in closed { pipeline.close() }
        for video in videos.removeAll() { video.close() }
        // A GPU stream replays from its first byte on the next connection.
        for window in windows.values { endGPUStream(of: window) }
        _ = gpuFeeds.removeAll()
        sound?.stop()
        sound = nil
        pendingGeometry.removeAll()
        requestedOverscan.removeAll()
        scrollSeq.removeAll()
        for window in windows.values { window.scrollReports.forget() }
        if !keepWindows { windowDisplays.removeAll() }
        lastVsync.removeAll()
        buttons = 0 // the server releases what was held when the connection ends
        preedit = nil
        reconciling = nil
        echo.reset()
        if keepWindows, server?.epoch != nil {
            for pipeline in closed where windows[pipeline.windowID] != nil { retained[pipeline.windowID] = pipeline }
            for window in windows.values where !window.videos.isEmpty || !window.retiringVideos.isEmpty {
                window.videos = []
                window.retiringVideos = [:]
                window.videoLayout &+= 1
            }
            // A window whose pipeline was already gone cannot be resumed.
            for id in windows.keys where retained[id] == nil { removeWindow(id) }
            return
        }
        dropRetained()
        for window in windows.values { endGame(of: window) }
        windows.removeAll()
        placement.removeAll()
        focusedWindow = nil
        textInput = nil
        surroundingText = nil
    }

    private func dropRetained() {
        for id in retained.keys { removeWindow(id) }
        retained.removeAll()
    }

    private func removeWindow(_ id: Int) {
        endGame(of: windows[id])
        endGPUStream(of: windows[id])
        windows[id] = nil
        placement[id] = nil
        pendingGeometry[id] = nil
        windowDisplays[id] = nil
        if focusedWindow == id { focusedWindow = nil }
        if textInput?.window == id { textInput = nil }
        if surroundingText?.window == id { surroundingText = nil }
    }

    private func send(_ message: ClientMessage) {
        stream?.send(DisplayFraming.encode(message.frame))
    }

    private func sendHello() {
        state = .authenticating
        send(.hello(token: displayToken, decoders: decoders, displays: displays, videoDecoders: videoDecoders.isEmpty ? nil : videoDecoders,
                    audioDecoders: playsAudio ? ["opus"] : nil, wasm: runsGames, gpu: rendersGPUStreams,
                    scaledMotion: true, webview: runsGames, devices: devices != nil, scroll: LocalScrollController.enabled))
    }

    // MARK: Server messages

    func handle(_ messages: [ServerMessage]) {
        for message in messages {
            switch message {
            case .hello(let hello): didReceiveHello(hello)
            case .windowCreate(let fields): createWindow(fields)
            case .windowUpdate(let fields): updateWindow(fields)
            case .windowDestroy(let id): destroyWindow(id)
            case .cursorImage:
                cursorName = nil
                cursorSerial &+= 1
            case .cursorNamed(let name):
                cursorName = name.lowercased()
                cursorSerial &+= 1
            case .scrollTree(let tree):
                windows[tree.window]?.scrollReports.record(tree)
            case .textInput(let window, let enabled, let purpose, let surrounding):
                // Surrounding text arrives with every edit; only a change of field or state is news for the cursor.
                if textInput?.window != window || textInput?.enabled != enabled || textInput?.purpose != purpose {
                    textInput = (window, enabled, purpose)
                    cursorSerial &+= 1
                }
                if enabled, let surrounding {
                    surroundingText = (window, (surroundingText?.serial ?? 0) &+ 1, surrounding)
                } else if surroundingText?.window == window {
                    surroundingText = nil
                }
            case .clipboard(let mime, let data):
                guard mime.hasPrefix("text/plain"), let text = String(data: data, encoding: .utf8) else { continue }
                lastClipboard = text
                onClipboardText?(text)
            case .notification(let id, let app, let summary, let body):
                onNotification?(RemoteNotification(id: id, appName: app, summary: summary, body: body))
            case .pong(let sent):
                let now = Self.monotonicMicros()
                if now >= sent {
                    latencyMs = Double(now - sent) / 1000
                    metrics.roundTrip(ms: Double(now - sent) / 1000)
                }
                LocalScrollProfile.note(String(format: "rtt sent=%.6f pong=%.6f rtt_ms=%.3f",
                                               Double(sent) / 1_000_000, Double(now) / 1_000_000, Double(now) / 1000 - Double(sent) / 1000))
                if let reconciling, reconciling.marker == sent { finishReconciling(reconciling.announced) }
            case .bye(let reason):
                isReplaced = reason == "replaced"
                fail(.bye(reason), Self.describe(bye: reason))
            case .videoCreate(let fields): addVideo(fields.id)
            case .videoUpdate(let fields): updateVideo(fields)
            case .videoDestroy(let id): retireVideo(id, after: 0)
            case .webviewCreate(let descriptor): createWebview(descriptor)
            case .webviewDestroy(let id): endGame(of: windows.values.first { $0.game?.id == id && $0.game?.webview != nil })
            case .gameCreate(let descriptor): createGame(descriptor)
            case .gameDestroy(let id): endGame(of: windows.values.first { $0.game?.id == id })
            case .gpuCreate(let id, let window): createGPUStream(id, window: window)
            case .gpuDestroy(let id, let reason):
                guard let window = windows.values.first(where: { $0.gpuStream?.id == id }) else { continue }
                if let reason {
                    // The window keeps the stream's view, saying why it ended.
                    gpuFeeds[id] = nil
                    window.gpuStream?.end(reason: reason)
                } else {
                    endGPUStream(of: window)
                }
            case .deviceStatus, .deviceOpen, .deviceClose, .deviceRumble, .deviceKeyframe:
                devices?.handle(message)
            case .frame, .tile, .videoFrame, .videoPresent, .gpuData, .audio, .unknown, .malformed:
                continue // pictures and streams were routed on the socket's queue; unknown types are not used
            }
        }
    }

    nonisolated static func describe(bye reason: String) -> String {
        switch reason {
        case "auth": "The computer's display did not accept this session's token."
        case "version": "The computer's display speaks a newer protocol. Update Caboose."
        case "shutdown": "The computer's display stopped."
        case "replaced": "Another device is showing this computer's display."
        case "protocol": "The display connection broke: the computer could not understand the phone."
        default: reason.isEmpty ? "The computer's display closed the connection." : reason
        }
    }

    private func didReceiveHello(_ hello: ServerHello) {
        guard hello.version == DisplayProtocol.version else {
            return fail(.incompatible, "The computer's display speaks protocol version \(hello.version); this Caboose speaks \(DisplayProtocol.version).")
        }
        let sameServer = hello.epoch != nil && hello.epoch == server?.epoch
        server = hello
        if !sameServer { dropRetained() }
        state = .ready
        let now = CACurrentMediaTime()
        watchdog?.ready(at: now)
        lastPing = now
        // The server writes every window.create of a hello before it reads the next message,
        // and answers a ping on the same ordered socket, so this pong ends the burst.
        let marker = Self.monotonicMicros()
        if hello.epoch != nil { reconciling = (marker, []) }
        announcedGames.removeAll()
        send(.ping(micros: marker))
        for window in windows.values { applyCapabilities(window, xwayland: nil) }
        attachDevices()
    }

    /// Offers the phone's hardware on this connection when its server accepts devices.
    private func attachDevices() {
        guard let devices else { return }
        guard has("devices"), let stream else { return devices.detach() }
        devices.attach(DeviceOutput(send: { message in stream.send(DisplayFraming.encode(message.frame)) },
                                    backlog: { stream.sendBacklog }))
    }

    /// The hello's windows have all been announced: a kept window that was not is gone.
    private func finishReconciling(_ announced: Set<Int>) {
        reconciling = nil
        for (id, pipeline) in retained where !announced.contains(id) {
            pipeline.close()
            removeWindow(id)
        }
        retained.removeAll()
        for window in windows.values where window.game.map({ !announcedGames.contains($0.id) }) == true { endGame(of: window) }
        // Every app this computer runs here is announced: a kept page none took ends.
        if let computer = gameHost?.webviewComputerKey { AgentAppPages.shared.settled(computer: computer) }
        windowsAnnounced &+= 1
    }

    // MARK: Liveness

    private func startLivenessTimer() {
        livenessTimer?.invalidate()
        // Common modes, so pings continue while a scroll view tracks a finger.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            // A session let go without disconnect() stops its own timer.
            guard self != nil else { return timer.invalidate() }
            Task { @MainActor in self?.checkLiveness(at: CACurrentMediaTime()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    /// Pings while connected, and gives the connection up once the watchdog finds it silent.
    func checkLiveness(at now: CFTimeInterval) {
        guard var watchdog else { return }
        if state == .ready, now - lastPing >= LinkWatchdog.pingInterval {
            lastPing = now
            send(.ping(micros: Self.monotonicMicros()))
        }
        let verdict = watchdog.verdict(at: now, lastReceive: metrics.lastReceiveTime)
        self.watchdog = watchdog
        if case .stalled(let reason) = verdict { fail(.stalled(reason), reason) }
    }

    /// The network path changed: ask the server for an answer now, and give the connection
    /// up if none comes within `LinkWatchdog.probeLimit`.
    public func probeLiveness() {
        guard state == .ready else { return }
        let now = CACurrentMediaTime()
        watchdog?.probe(at: now)
        lastPing = now
        send(.ping(micros: Self.monotonicMicros()))
    }

    /// What this connection has measured so far.
    public var health: DisplayLinkHealth {
        var health = metrics.snapshot(at: CACurrentMediaTime())
        health.sendBacklog = stream?.sendBacklog
        health.typingEchoMs = echo.median
        health.keyAwaitingPicture = echo.pendingSeconds
        return health
    }

    /// Seconds since the window's last picture on this connection; nil before its first.
    public func pictureAge(of window: RemoteWindow) -> Double? {
        metrics.pictureAge(window: window.id, at: CACurrentMediaTime())
    }

    private func createWindow(_ fields: WindowFields) {
        guard let pipeline = pipelines[fields.id] else { return }
        let kind = fields.kind ?? .toplevel
        let geometry = fields.geometry ?? CGRect(x: 0, y: 0, width: pipeline.surface.pixelSize.width, height: pipeline.surface.pixelSize.height)
        placement[fields.id] = (kind, fields.parent, geometry)
        reconciling?.announced.insert(fields.id)
        // The same window from the same server epoch, painting on into the picture it kept.
        if let kept = windows[fields.id], kept.surface === pipeline.surface {
            retained[fields.id] = nil
            apply(fields, to: kept)
            place(kept)
            return
        }
        let window = RemoteWindow(id: fields.id, frame: absoluteFrame(fields.id) ?? geometry, overrideRedirect: kind == .popup,
                                  surface: pipeline.surface)
        apply(fields, to: window)
        windows[fields.id] = window
        if let frame = cachedFrame?(fields.id) { pipeline.seed(frame) }
    }

    private func updateWindow(_ fields: WindowFields) {
        guard let window = windows[fields.id], var entry = placement[fields.id] else { return }
        if let kind = fields.kind { entry.kind = kind }
        if fields.parent != nil { entry.parent = fields.parent }
        if let geometry = fields.geometry {
            // Keep a newer requested position for up to a second. Content size always
            // follows the server; a client is allowed to constrain the request.
            let stale = pendingGeometry[fields.id].map { geometry != $0.geometry && CACurrentMediaTime() - $0.at < 1 } ?? false
            if !stale {
                pendingGeometry[fields.id] = nil
                entry.geometry = geometry
            } else {
                // A client may constrain or refuse a requested size. Its reported size
                // is also the coordinate space of its controls, even while a newer
                // placement request is in flight.
                entry.geometry.size = geometry.size
            }
        }
        placement[fields.id] = entry
        apply(fields, to: window)
        if fields.geometry != nil || fields.parent != nil { place(window) }
    }

    private func destroyWindow(_ id: Int) {
        retained[id] = nil
        for video in windows[id]?.videos ?? [] { removeVideo(video.id) }
        endGame(of: windows[id])
        endGPUStream(of: windows[id])
        pipelines.remove(id)?.close()
        windows[id] = nil
        placement[id] = nil
        pendingGeometry[id] = nil
        windowDisplays[id] = nil
        if focusedWindow == id { focusedWindow = nil }
        if textInput?.window == id { textInput = nil }
        if surroundingText?.window == id { surroundingText = nil }
    }

    // MARK: Video streams

    /// The stream was made on the socket's queue, so its first pictures are already playing.
    private func addVideo(_ id: Int) {
        guard let video = videos[id] else { return }
        guard let window = windows[video.window] else {
            videos.remove(id)?.close() // a stream for a window this connection does not have
            return
        }
        window.videos = (window.videos.filter { $0.id != id } + [video]).sorted { $0.z < $1.z }
        window.videoLayout &+= 1
    }

    private func updateVideo(_ fields: VideoStreamFields) {
        guard let video = videos[fields.id], let window = windows[video.window] else { return }
        if let rect = fields.rect { video.rect = rect }
        if let clip = fields.clip { video.clip = clip }
        if let z = fields.z { video.z = z }
        window.videos.sort { $0.z < $1.z }
        window.videoLayout &+= 1
    }

    /// The server ended a video. It painted the region back into the window first, so the
    /// video stays on screen until the window's picture `generation` has been shown (a second
    /// at most, for a window no view is showing).
    func retireVideo(_ id: Int, after generation: UInt64) {
        guard let video = videos.remove(id) else { return }
        video.close()
        guard let window = windows[video.window] else { return }
        window.videos.removeAll { $0.id == id }
        let container = ObjectIdentifier(video.container)
        if generation > 0 {
            window.retiringVideos[container] = generation
            Task { @MainActor [weak window] in
                try? await Task.sleep(for: .seconds(1))
                guard let window, window.retiringVideos.removeValue(forKey: container) != nil else { return }
                window.videoLayout &+= 1
            }
        }
        window.videoLayout &+= 1
    }

    private func removeVideo(_ id: Int) { retireVideo(id, after: 0) }

    // MARK: GPU streams

    /// The window is drawn on this device from stream `id`; its bytes are already arriving on
    /// the socket's queue.
    private func createGPUStream(_ id: Int, window windowID: Int) {
        guard rendersGPUStreams, let window = windows[windowID], let feed = gpuFeeds[id], let connection = stream else { return }
        if window.gpuStream?.id == id { return }
        endGPUStream(of: window)
        window.gpuStream = RemoteGPUStream(id: id, window: windowID, feed: feed) { [weak self, weak connection, weak window, weak feed] bytes in
            guard let self, let connection, let window, let feed,
                  self.stream === connection, self.windows[windowID] === window,
                  window.gpuStream?.feed === feed, case .ready = self.state else { return }
            self.send(.gpuAck(id: id, offset: bytes))
        }
    }

    private func endGPUStream(of window: RemoteWindow?) {
        guard let window, let stream = window.gpuStream else { return }
        window.gpuStream = nil
        gpuFeeds[stream.id] = nil
        stream.end()
    }

    // MARK: Games

    /// The window's game runs on this device. The same game again (a resumed connection's
    /// burst) keeps its object and its running page.
    private func createGame(_ descriptor: GameDescriptor) {
        guard runsGames, let window = windows[descriptor.window] else { return }
        announcedGames.insert(descriptor.id)
        if let game = window.game, game.id == descriptor.id {
            // Declined (its saves written) while no connection could say so, or said on a
            // connection that went before the computer answered: this one says it.
            if game.isDeclineReady, let reason = game.declineReason { declineGame(game, reason: reason) }
            return
        }
        endGame(of: window)
        let game = RemoteGame(descriptor, host: gameHost, picture: window.surface)
        game.onDecline = { [weak self, weak game] reason in
            guard let self, let game else { return }
            self.declineGame(game, reason: reason)
        }
        window.game = game
    }

    private func createWebview(_ descriptor: WebviewDescriptor) {
        guard runsGames, let window = windows[descriptor.window] else { return }
        announcedGames.insert(descriptor.id)
        if let game = window.game, game.id == descriptor.id, game.webview == descriptor {
            if game.isDeclineReady, let reason = game.declineReason { declineGame(game, reason: reason) }
            else { game.resumeSink?() }
            return
        }
        endGame(of: window)
        let game = RemoteGame(GameDescriptor(id: descriptor.id, window: descriptor.window, root: descriptor.root, entry: descriptor.entry), host: gameHost, picture: window.surface, webview: descriptor)
        game.onDecline = { [weak self, weak game] reason in
            guard let self, let game else { return }
            self.declineGame(game, reason: reason)
        }
        window.game = game
        // The app's page kept playing while Caboose was away: it carries on as this game.
        AgentAppPages.shared.adopt(game)
    }

    /// Asks the computer to run `game` itself (`game.decline`): only once its saves are
    /// written, while it is its window's game, announced on the current ready connection, and
    /// once per connection. A game declined while the connection is down, or whose decline
    /// the computer never answered before the connection went, says so again when the same
    /// server announces it on the next connection.
    func declineGame(_ game: RemoteGame, reason: String) {
        guard game.isDeclineReady, game.declineSentOn != connections, !game.isEnded, stream != nil,
              case .ready = state, announcedGames.contains(game.id),
              let window = windows[game.descriptor.window], window.game === game else { return }
        game.declineSentOn = connections
        if game.webview != nil { send(.webviewDecline(id: game.id, reason: reason)) }
        else { send(.gameDecline(id: game.id, reason: reason)) }
    }

    private func endGame(of window: RemoteWindow?) {
        guard let window, let game = window.game else { return }
        window.game = nil
        game.end()
    }

    private func apply(_ fields: WindowFields, to window: RemoteWindow) {
        if let display = fields.display { windowDisplays[window.id] = display }
        if let title = fields.title { window.title = title }
        if let app = fields.appID { window.appClass = (app, app) }
        if let place = placement[fields.id] {
            window.transientFor = place.parent
            window.isOverrideRedirect = place.kind == .popup
            window.windowTypes = switch place.kind {
            case .toplevel: []
            case .popup: ["POPUP_MENU"]
            case .dialog: ["DIALOG"]
            }
        }
        if let fullscreen = fields.fullscreen { window.isFullscreen = fullscreen }
        if let alpha = fields.alpha { window.hasAlpha = alpha }
        if let overscan = fields.overscan { window.overscan = overscan }
        if let size = fields.minimumSize { window.minimumSize = size }
        if let size = fields.maximumSize { window.maximumSize = size }
        if let icon = fields.icon, let source = CGImageSourceCreateWithData(icon as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            window.icon = image
        }
        applyCapabilities(window, xwayland: fields.xwayland)
    }

    private var xwaylandWindows = Set<Int>()

    /// Native Wayland windows take touch; Xwayland ones keep the pointer gestures, since most
    /// X11 apps turn a touch drag into a selection. Pencil goes as a tablet to either.
    private func applyCapabilities(_ window: RemoteWindow, xwayland: Bool?) {
        if let xwayland {
            if xwayland { xwaylandWindows.insert(window.id) } else { xwaylandWindows.remove(window.id) }
        }
        window.acceptsTouch = has("touch") && !xwaylandWindows.contains(window.id)
        window.acceptsPencil = has("pencil")
    }

    /// The window's frame in display pixels, from its own geometry and its parent's frame.
    private func absoluteFrame(_ id: Int) -> CGRect? {
        guard let place = placement[id] else { return nil }
        guard place.kind != .toplevel, let parent = place.parent, let parentFrame = windows[parent]?.frame ?? absoluteFrame(parent) else {
            return place.geometry
        }
        return place.geometry.offsetBy(dx: parentFrame.minX, dy: parentFrame.minY)
    }

    /// Re-places a window and the popups and dialogs that hang off it.
    private func place(_ window: RemoteWindow) {
        // The surface follows the sizes the server confirms, on the socket's queue in order with
        // the pictures; only the frame the app lays out by moves here.
        guard let frame = absoluteFrame(window.id) else { return }
        window.frame = frame
        for (id, place) in placement where place.parent == window.id && place.kind != .toplevel {
            if let child = windows[id] { self.place(child) }
        }
    }

    // A GPU owner must not bind the old extent while a known resize is in flight.
    // Match only the compositor's exact physical/logical round trip on the same
    // assigned output and scale. This does not turn metadata into a configure ACK.
    func pendingPresentationSize(_ window: RemoteWindow) -> CGSize? {
        guard let pending = pendingGeometry[window.id] else { return nil }
        guard let sentDisplay = pending.display else { return pending.geometry.size }
        guard assignedDisplay(window.id) == sentDisplay else { return .zero }
        return LiveGPUDrawableGeometry.quantizedRequest(pending.geometry.size, scale: sentDisplay.scale) ?? .zero
    }

    private func assignedDisplay(_ windowID: Int) -> DisplayInfo? {
        guard let id = windowDisplays[windowID] else { return nil }
        return displays.first { $0.id == id }
    }

    // MARK: Windows

    public func configure(_ window: RemoteWindow, frame: CGRect, state: [String: Bool] = [:]) {
        let fullscreen = state["fullscreen"] ?? window.isFullscreen
        // All layouts share this boundary. Fullscreen sizing belongs to the
        // compositor; only explicit state transitions travel without geometry.
        if fullscreen {
            if state["fullscreen"] == true {
                send(.configure(window: window.id, geometry: nil, fullscreen: true, maximized: state["maximized"]))
                window.isFullscreen = true
            }
            return
        }
        guard let rounded = WindowSizePolicy.request(frame, minimum: window.minimumSize,
            maximum: window.maximumSize, fullscreen: false) else { return }
        var geometry = rounded
        if var entry = placement[window.id] {
            if entry.kind != .toplevel, let parent = entry.parent.flatMap({ windows[$0] }) {
                geometry = rounded.offsetBy(dx: -parent.frame.minX, dy: -parent.frame.minY)
            }
            // Placement can follow the finger immediately; size must follow the app.
            // Fixed-size dialogs may never answer a resize with another geometry event.
            // Pretending they accepted it stretches their picture and misroutes taps.
            entry.geometry.origin = geometry.origin
            placement[window.id] = entry
        }
        pendingGeometry[window.id] = (geometry, CACurrentMediaTime(), assignedDisplay(window.id))
        send(.configure(window: window.id, geometry: geometry, fullscreen: state["fullscreen"], maximized: state["maximized"]))
        if let fullscreen = state["fullscreen"] { window.isFullscreen = fullscreen }
        place(window)
    }

    /// Asks the app to lay `window` out `size` larger than its geometry, right and below, so
    /// its pictures hold content beyond what the phone shows; `.zero` ends it. The server
    /// reports the overscan actually applied in `window.update`.
    public func requestOverscan(_ window: RemoteWindow, _ size: CGSize) {
        guard state == .ready, window.game == nil, requestedOverscan[window.id, default: .zero] != size else { return }
        requestedOverscan[window.id] = size
        send(.configure(window: window.id, geometry: nil, overscan: size))
    }

    public func focus(_ window: RemoteWindow?) {
        if let game = gameHoldingInput, game !== window?.game {
            game.releaseInput()
            gameHoldingInput = nil
        }
        guard let window else {
            if let focusedWindow { send(.configure(window: focusedWindow, geometry: nil, activated: false)) }
            focusedWindow = nil
            return
        }
        focusedWindow = window.id
        window.raisedAt = Date()
        send(.configure(window: window.id, geometry: nil, activated: true))
    }

    /// A game window first waits, for up to five seconds, for the game's saves still on their way.
    public func close(_ window: RemoteWindow) {
        CloseDiagnostics.record(window: window, connection: connections, epoch: epoch)
        guard let game = window.game else { return send(.close(window: window.id)) }
        guard let connection = stream else { return }
        let id = window.id
        Task { [weak self, weak connection, weak window] in
            await game.flushSaves(within: 5)
            guard let self, let connection, let window,
                  self.stream === connection, self.windows[id] === window,
                  window.game === game, !game.isEnded, case .ready = self.state else { return }
            self.send(.close(window: id))
        }
    }

    /// A keyframe repaints the whole window.
    public func refresh(_ window: RemoteWindow) { send(.requestKeyframe(window: window.id)) }

    public func reconfigure(_ capabilities: ClientCapabilities) {
        let next = [DisplayInfo(capabilities)]
        guard displays != next else { return }
        displays = next
        lastVsync.removeAll()
        // Before the hello, the new screen goes in the hello itself.
        if state == .ready || state == .authenticating { send(.displays(displays)) }
    }

    public func offerClipboard(_ text: String) {
        guard state == .ready, has("clipboard"), text != lastClipboard else { return }
        lastClipboard = text
        send(.clipboard(mime: "text/plain;charset=utf-8", data: Data(text.utf8)))
    }

    // MARK: Pacing

    public func displayWillRefresh(_ displayID: Int?, targetTimestamp: CFTimeInterval) {
        guard state == .ready, has("vsync"), targetTimestamp > 0 else { return }
        // Explicit IDs are never redirected. An unassigned view uses our announced
        // primary, or the retained server primary only during empty-set bootstrap.
        let ids = displays.isEmpty ? (server?.displays ?? []) : displays.map(\.id)
        guard let display = displayID ?? ids.first, ids.contains(display) else { return }
        let micros = UInt64(targetTimestamp * 1_000_000)
        // Every window view on a screen ticks with the same timestamp; send each refresh once.
        if let last = lastVsync[display], micros < last + 1000 { return }
        lastVsync[display] = micros
        send(.vsync(display: display, micros: micros))
    }

    nonisolated static func monotonicMicros() -> UInt64 { UInt64(CACurrentMediaTime() * 1_000_000) }

    /// Shift, Control, Caps Lock, Meta, Alt, Super and Hyper (X keysyms 0xFFE1–0xFFEE).
    nonisolated static func isModifier(_ keysym: Int) -> Bool { (0xFFE1 ... 0xFFEE).contains(keysym) }

    // MARK: Input — positions are in the window's own pixels.
    //
    // A window whose game runs on this device takes its input there: none addressed to it
    // goes to the computer (docs/game-handoff.md, "Input"). Touch and Pencil on the window are
    // the page's own; pointer, scroll, keys and text from the app's other controls (a
    // trackpad, its keyboard) go to the page as DOM events.

    public func pointerMove(in window: RemoteWindow, to point: CGPoint, modifiers: [String] = []) {
        if let game = window.game { return game.pointerMove(to: point, in: window.frame.size, modifiers: modifiers) }
        send(.pointer(window: window.id, x: Double(point.x), y: Double(point.y), buttons: buttons, scroll: nil))
    }

    public func pointerButton(in window: RemoteWindow, button: Int, pressed: Bool, at point: CGPoint, modifiers: [String] = []) {
        if let game = window.game {
            if pressed { focusInput(on: window) }
            return game.pointerButton(button, pressed: pressed, at: point, in: window.frame.size, modifiers: modifiers)
        }
        let bit = PointerButtons.bit(forXButton: button)
        guard bit != 0 else { return }
        if pressed { inputLeftGames(for: window) }
        if pressed { buttons |= bit } else { buttons &= ~bit }
        send(.pointer(window: window.id, x: Double(point.x), y: Double(point.y), buttons: buttons, scroll: nil))
    }

    /// Wayland scrolls by any amount, so every swipe is precise.
    public func scroll(in window: RemoteWindow, dx: CGFloat, dy: CGFloat, at point: CGPoint, modifiers: [String] = []) {
        guard dx != 0 || dy != 0 else { return }
        if let game = window.game { return game.scroll(dx: dx, dy: dy, at: point, in: window.frame.size, modifiers: modifiers) }
        send(.pointer(window: window.id, x: Double(point.x), y: Double(point.y), buttons: buttons,
                      scroll: (Double(dx), Double(dy), true), scrollSeq: nextScrollSeq(window.id)))
    }

    private func nextScrollSeq(_ window: Int) -> UInt64 {
        let seq = scrollSeq[window, default: 0] + 1
        scrollSeq[window] = seq
        return seq
    }

    public func scrollTarget(in window: RemoteWindow, scroller: Int, delta: CGPoint) -> Bool {
        guard state == .ready, window.game == nil, delta != .zero else { return state == .ready }
        let seq = nextScrollSeq(window.id)
        window.scrollReports.sent(seq: seq, delta: delta)
        send(.scrollTarget(window: window.id, scroller: scroller, seq: seq, delta: delta))
        return true
    }

    public func resetScroll() {}

    /// The window keys and text go to: `window`, or the focused window when none is named.
    private func inputTarget(_ window: RemoteWindow?) -> RemoteWindow? {
        window ?? focusedWindow.flatMap { windows[$0] }
    }

    /// A press, a key or text went to `window`, which runs no game: the game that had the
    /// input releases what it held, even where nothing changes focus on the computer.
    private func inputLeftGames(for window: RemoteWindow?) {
        guard let game = gameHoldingInput, window?.game !== game else { return }
        game.releaseInput()
        gameHoldingInput = nil
    }

    /// Input goes to `window` now: a game window focuses on the computer like any other, and
    /// the game that had the input before releases what it held.
    private func focusInput(on window: RemoteWindow) {
        if let game = gameHoldingInput, game !== window.game { game.releaseInput() }
        gameHoldingInput = window.game
        if focusedWindow != window.id { focus(window) }
    }

    public func key(_ stroke: KeyStroke, pressed: Bool, in window: RemoteWindow?, extraModifiers: [String] = []) {
        if let target = inputTarget(window), let game = target.game {
            if pressed { focusInput(on: target) }
            return game.key(stroke, pressed: pressed, extraModifiers: extraModifiers)
        }
        if pressed { inputLeftGames(for: inputTarget(window)) }
        if let window {
            // A modifier alone draws nothing, so it would wait for a picture that never comes.
            if pressed, !Self.isModifier(stroke.keyval) { echo.keySent(window.id) }
            if focusedWindow != window.id { focus(window) }
        }
        let modifiers = Array(Set(stroke.modifiers + extraModifiers)).sorted()
        send(.key(keysym: stroke.keyval, pressed: pressed, modifiers: modifiers))
    }

    /// Text goes as a text-input-v3 commit; the server types it as keys into apps without one.
    public func type(_ text: String, in window: RemoteWindow?) {
        guard !text.isEmpty else { return }
        if let target = inputTarget(window), let game = target.game {
            focusInput(on: target)
            return game.type(text)
        }
        inputLeftGames(for: inputTarget(window))
        prepareText(for: window)
        sendCommittedText(text)
    }

    public func edit(_ edits: [TypingBuffer.Edit], in window: RemoteWindow?) {
        if let target = inputTarget(window), let game = target.game {
            focusInput(on: target)
            return game.edit(edits)
        }
        inputLeftGames(for: inputTarget(window))
        var deleteBefore = 0
        var commit = ""
        for edit in edits {
            switch edit {
            case .backspace(let count):
                let dropped = min(count, commit.count)
                commit.removeLast(dropped)
                deleteBefore += count - dropped
            case .type(let text):
                commit += text
            }
        }
        guard deleteBefore > 0 || !commit.isEmpty else { return }
        prepareText(for: window)
        sendCommittedText(commit, deleteBefore: deleteBefore)
    }

    /// A newline is a Return key, not an IME commit: single-line fields such as
    /// Chromium's address bar ignore committed newlines instead of submitting.
    private func sendCommittedText(_ text: String, deleteBefore: Int = 0) {
        guard text.contains(where: \.isNewline) else {
            if !text.isEmpty { preedit = nil }
            send(.text(commit: text.isEmpty ? nil : text, preedit: preedit?.text, cursor: preedit?.cursor,
                       deleteBefore: deleteBefore > 0 ? deleteBefore : nil))
            return
        }
        var pending = ""
        var deletions = deleteBefore
        func flush() {
            guard !pending.isEmpty || deletions > 0 else { return }
            send(.text(commit: pending.isEmpty ? nil : pending,
                       deleteBefore: deletions > 0 ? deletions : nil))
            if !pending.isEmpty { preedit = nil }
            pending = ""
            deletions = 0
        }
        for character in text {
            if character.isNewline {
                flush()
                if preedit != nil {
                    preedit = nil
                    send(.text(commit: nil, preedit: ""))
                }
                // CRLF is one Character, so pasted Windows lines submit once too.
                send(.key(keysym: 0xFF0D, pressed: true, modifiers: []))
                send(.key(keysym: 0xFF0D, pressed: false, modifiers: []))
            } else {
                pending.append(character)
            }
        }
        flush()
    }

    /// Compose on the server only where the focused app has text-input-v3 enabled; anywhere
    /// else the composition is typed live, so an X11 app still shows it.
    public var composesText: Bool {
        guard has("text-input-v3"), let textInput, textInput.enabled else { return false }
        return focusedWindow == nil || textInput.window == focusedWindow
    }

    /// A game page takes text as keys: a composition reaches it once committed, as an edit.
    public func compose(_ text: String, selection: NSRange, in window: RemoteWindow?) {
        guard inputTarget(window)?.game == nil else { return }
        if text.isEmpty {
            guard preedit != nil else { return } // already ended by its commit
            preedit = nil
            prepareText(for: window)
            send(.text(commit: nil, preedit: ""))
            return
        }
        let cursor = Self.utf8Range(selection, in: text)
        preedit = (text, cursor)
        prepareText(for: window)
        send(.text(commit: nil, preedit: text, cursor: cursor))
    }

    private func prepareText(for window: RemoteWindow?) {
        guard let window else { return }
        echo.keySent(window.id)
        if focusedWindow != window.id { focus(window) }
    }

    /// A UTF-16 range within `text` as UTF-8 byte offsets, which is what text-input-v3 counts.
    nonisolated static func utf8Range(_ range: NSRange, in text: String) -> (Int, Int) {
        let string = text as NSString
        let start = min(max(0, range.location), string.length)
        let end = min(max(start, range.location + range.length), string.length)
        return (string.substring(to: start).utf8.count, string.substring(to: end).utf8.count)
    }

    public func touch(_ points: [TouchPoint], in window: RemoteWindow) {
        guard !points.isEmpty, window.game == nil else { return }
        if points.contains(where: { $0.phase == .down }) { inputLeftGames(for: window) }
        if points.contains(where: { $0.phase == .down }), focusedWindow != window.id { focus(window) }
        send(.touch(window: window.id, points: points))
    }

    public func pencil(_ sample: PencilSample, in window: RemoteWindow) {
        guard window.game == nil else { return }
        if sample.phase == .down { inputLeftGames(for: window) }
        if sample.phase == .down, focusedWindow != window.id { focus(window) }
        send(.pencil(window: window.id, sample))
    }

    // MARK: Text focus

    public var cursorIsText: Bool? {
        if has("text-input-v3"), let textInput, focusedWindow == nil || textInput.window == focusedWindow {
            return textInput.enabled
        }
        guard let cursorName else { return nil }
        // Xwayland supplies a cursor surface; the compositor currently represents
        // that unclassified bitmap as "default", even when it draws an I-beam.
        // It is not evidence that the focused X11 field rejects typing.
        if cursorName == "default", let focusedWindow, xwaylandWindows.contains(focusedWindow) { return nil }
        return ["text", "vertical-text", "xterm", "ibeam"].contains(cursorName)
    }

    public var textPurpose: String? {
        guard let textInput, textInput.enabled else { return nil }
        return textInput.purpose
    }
}

/// The socket side of a session: reassembles messages, creates each window's pipeline the
/// moment the window is announced (its keyframe follows at once), and sends pictures to them.
private final class Incoming: @unchecked Sendable {
    private var parser = DisplayFrameParser()
    private let pipelines: FramePipelineRegistry
    private let videos: VideoRegistry
    private let gpuFeeds: GPUStreamFeeds
    private let clock: MediaClock
    private let sound: SoundPlayer?
    private let echo: EchoMeter
    private let metrics: ConnectionMetrics
    private var carried: Carried
    private let retire: @Sendable (Int, UInt64) -> Void
    private let makeDecoder: (DisplayCodec) -> PictureDecoder
    private let send: @Sendable (ClientMessage) -> Void
    private let suspendedLock = NSLock()
    private var suspended = false

    /// While suspended, pictures are acknowledged unseen and sound plays on.
    func setPicturesSuspended(_ value: Bool) { suspendedLock.withLock { suspended = value } }

    init(pipelines: FramePipelineRegistry, videos: VideoRegistry, gpuFeeds: GPUStreamFeeds, clock: MediaClock, sound: SoundPlayer?, echo: EchoMeter,
         metrics: ConnectionMetrics, carried: Carried,
         makeDecoder: @escaping (DisplayCodec) -> PictureDecoder, retire: @escaping @Sendable (Int, UInt64) -> Void,
         send: @escaping @Sendable (ClientMessage) -> Void) {
        self.retire = retire
        self.pipelines = pipelines
        self.videos = videos
        self.gpuFeeds = gpuFeeds
        self.clock = clock
        self.sound = sound
        self.echo = echo
        self.metrics = metrics
        self.carried = carried
        self.makeDecoder = makeDecoder
        self.send = send
    }

    /// Everything that is not a picture, for the main actor.
    func receive(_ data: Data, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> [ServerMessage] {
        let incomingAt = ProcessInfo.processInfo.systemUptime
        sound?.timing.update { $0.receive(at: receivedAt, incoming: incomingAt) }
        defer {
            let finishedAt = ProcessInfo.processInfo.systemUptime
            sound?.timing.update { $0.finishIncoming(start: incomingAt, end: finishedAt) }
        }
        var others: [ServerMessage] = []
        let picturesSuspended = suspendedLock.withLock { suspended }
        for frame in try parser.append(data) {
            let message = ServerMessage(frame)
            if picturesSuspended {
                // The app is in the background, where it cannot decode or show pictures:
                // each is acknowledged unseen, so window flow control keeps the windows
                // running (at the minimised rate, without vsync) and video sources unblocked.
                switch message {
                case .frame(let picture):
                    send(.ack(window: picture.window, ptsMicros: picture.ptsMicros, decodedMicros: 0)); continue
                case .videoFrame(let frame):
                    send(.videoAck(video: frame.video, seq: frame.seq)); continue
                case .tile, .videoPresent:
                    continue
                default:
                    break
                }
            }
            switch message {
            case .frame(let picture):
                guard let pipeline = pipelines[picture.window] else { continue }
                echo.drew(picture.window)
                pipeline.frame(picture)
            case .tile(let tile):
                pipelines[tile.window]?.tile(tile)
            case .videoFrame(let frame):
                videos[frame.video]?.frame(frame)
            case .videoPresent(let id, let seq, let pts):
                videos[id]?.present(seq: seq, at: pts)
            case .audio(let packet):
                sound?.play(packet, receivedAt: receivedAt)
            case .videoDestroy(let id):
                // The server repainted the region into the window just before; the video goes once
                // that picture is applied (and the view has shown it), never before.
                guard let window = videos[id]?.window, let pipeline = pipelines[window] else {
                    retire(id, 0)
                    continue
                }
                let retire = retire
                pipeline.whenApplied { generation in retire(id, generation) }
            case .gpuCreate(let id, _):
                // Made here, like a window's pipeline: the stream's bytes follow at once.
                if gpuFeeds[id] == nil { gpuFeeds[id] = GPUStreamFeed() }
                others.append(message)
            case .gpuData(let id, let offset, let data):
                gpuFeeds[id]?.receive(offset: offset, data: data)
            case .videoCreate(let fields):
                // Made here, like a window's pipeline, because its first picture follows at once.
                if videos[fields.id] == nil, let video = RemoteVideo(fields, clock: clock, send: send) { videos[fields.id] = video }
                others.append(message)
            case .hello(let hello):
                carried.hello(epoch: hello.epoch)
                others.append(message)
            case .windowCreate(let fields):
                if pipelines[fields.id] == nil {
                    let size = fields.geometry?.size ?? CGSize(width: 1, height: 1)
                    let width = max(1, Int(size.width)), height = max(1, Int(size.height))
                    pipelines[fields.id] = if let closed = carried.take(fields.id) {
                        FramePipeline(succeeding: closed, width: width, height: height, metrics: metrics, makeDecoder: makeDecoder, send: send)
                    } else {
                        FramePipeline(windowID: fields.id, width: width, height: height, metrics: metrics, makeDecoder: makeDecoder, send: send)
                    }
                }
                others.append(message)
            case .windowUpdate(let fields):
                if let size = fields.geometry?.size, size.width > 0, size.height > 0 {
                    pipelines[fields.id]?.resize(width: Int(size.width), height: Int(size.height))
                }
                others.append(message)
            default:
                others.append(message)
            }
        }
        return others
    }
}

/// The closed pipelines of windows kept through a lost connection, offered to the next one
/// on its socket queue. They are taken only after a hello from the same server epoch, and
/// only for a window that hello's server announces again.
struct Carried {
    private var pipelines: [Int: FramePipeline]
    private let epoch: String?
    private var allowed = false

    init(_ pipelines: [Int: FramePipeline], epoch: String?) {
        self.pipelines = pipelines
        self.epoch = epoch
    }

    mutating func hello(epoch: String?) {
        allowed = epoch != nil && epoch == self.epoch
        if !allowed { pipelines.removeAll() }
    }

    mutating func take(_ id: Int) -> FramePipeline? {
        allowed ? pipelines.removeValue(forKey: id) : nil
    }
}

extension DisplayInfo {
    /// The screen the server lays windows out for.
    public init(_ capabilities: ClientCapabilities, id: Int = 0) {
        self.init(id: id, width: capabilities.desktopWidth, height: capabilities.desktopHeight,
                  scale: Double(capabilities.dpi) / 96, refreshHz: Double(capabilities.refreshRate), hdr: false)
    }
}
