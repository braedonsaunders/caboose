import CoreGraphics
import Foundation
import ImageIO
import Observation
import QuartzCore

/// One connection to caboose-display, the computer's own GPU display server, over the
/// Caboose Display Protocol (docs/display.md).
///
/// Every Linux window arrives as its own video stream, decoded in hardware into the same
/// `RemoteWindow` and `WindowSurface` the Xpra client fills, so the app shows either alike.
/// Pictures go straight from the socket's queue to their window's decode queue; everything
/// else is handled on the main actor.
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

    /// The pointer's shape by cursor-shape name ("default", "text", …), nil for an image cursor.
    public private(set) var cursorName: String?
    public private(set) var cursorSerial = 0
    /// The focused app's text-input-v3 state, where the server reports it.
    public private(set) var textInput: (window: Int, enabled: Bool, purpose: String?)?

    private let makeStream: () -> ByteStream
    private let displayToken: String
    private var displays: [DisplayInfo]
    private let decoders: [DisplayCodec]
    private let makeDecoder: (DisplayCodec) -> PictureDecoder
    private var stream: ByteStream?
    /// This connection's windows' decode pipelines; a new connection gets new ones, so nothing
    /// a closed socket still delivers can reach the next.
    private var pipelines = FramePipelineRegistry()
    private var videos = VideoRegistry()
    /// This connection's sound, on the clock its video layers share; nil when it plays none.
    private(set) var sound: SoundPlayer?
    private let echo = EchoMeter()
    private var pingTimer: Timer?
    private var buttons = 0
    private var focusedWindow: Int?
    /// What the server said about each window: geometry is relative to the parent for
    /// popups and dialogs, so their frames follow the parent.
    private var placement: [Int: (kind: WindowKind, parent: Int?, geometry: CGRect)] = [:]
    /// Geometry the phone asked for and the server has not confirmed yet, with when: updates
    /// still on their way from before it would otherwise snap a dragged window back.
    private var pendingGeometry: [Int: (geometry: CGRect, at: CFTimeInterval)] = [:]
    private var lastVsync: [Int: UInt64] = [:]
    private var preedit: (text: String, cursor: (Int, Int))?
    private var lastClipboard: String?

    /// - Parameters:
    ///   - displayURL: the host's `/v1/display` WebSocket.
    ///   - token: the host's bearer token.
    ///   - password: the per-wake display token from `/v1/session`, sent in hello.
    public convenience init(displayURL: URL, token: String, password: String, capabilities: ClientCapabilities) {
        self.init(stream: { WebSocketStream(url: displayURL, token: token) }, token: password,
                  displays: [DisplayInfo(capabilities)], decoders: Self.hardwareDecoders)
    }

    init(stream: @escaping () -> ByteStream, token: String, displays: [DisplayInfo], decoders: [DisplayCodec],
         makeDecoder: @escaping (DisplayCodec) -> PictureDecoder = FramePipeline.hardwareDecoder) {
        makeStream = stream
        displayToken = token
        self.displays = displays
        self.decoders = decoders
        self.makeDecoder = makeDecoder
    }

    /// What this device decodes in hardware, best first: HEVC, then AV1 where there is an
    /// AV1 decoder, then H.264.
    public nonisolated static var hardwareDecoders: [DisplayCodec] {
        AV1Decoder.isSupported ? [.hevc, .av1, .h264] : [.hevc, .h264]
    }

    private func has(_ feature: String) -> Bool { server?.features.contains(feature) ?? false }

    // MARK: Connection

    public func connect() {
        guard state == .idle || isClosed else { return }
        state = .connecting
        isReplaced = false
        let stream = makeStream()
        self.stream = stream
        pipelines = FramePipelineRegistry()
        videos = VideoRegistry()
        let clock = MediaClock()
        sound = playsAudio ? SoundPlayer(clock: clock) : nil
        let incoming = Incoming(pipelines: pipelines, videos: videos, clock: clock, sound: sound, echo: echo,
                                makeDecoder: makeDecoder, retire: { [weak self] id, generation in
            Task { @MainActor in if self?.stream === stream { self?.retireVideo(id, after: generation) } }
        }) { message in
            stream.send(DisplayFraming.encode(message.frame))
        }
        stream.open { [weak self] event in
            switch event {
            case .opened:
                Task { @MainActor in if self?.stream === stream { self?.sendHello() } }
            case .data(let data):
                do {
                    let others = try incoming.receive(data)
                    if !others.isEmpty { Task { @MainActor in if self?.stream === stream { self?.handle(others) } } }
                } catch {
                    stream.fail(error)
                }
            case .closed(let error):
                Task { @MainActor in if self?.stream === stream { self?.didClose(error) } }
            }
        }
    }

    public func disconnect() {
        stream?.close()
        stream = nil
        didClose(nil)
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    private func didClose(_ error: Error?) {
        pingTimer?.invalidate()
        pingTimer = nil
        if case .closed = state { return }
        state = .closed(reason: error.map { ($0 as? LocalizedError)?.errorDescription ?? String(describing: $0) })
        tearDown()
    }

    private func fail(_ reason: String) {
        pingTimer?.invalidate()
        pingTimer = nil
        stream?.close()
        stream = nil
        state = .closed(reason: reason)
        tearDown()
    }

    private func tearDown() {
        for pipeline in pipelines.removeAll() { pipeline.close() }
        for video in videos.removeAll() { video.close() }
        sound?.stop()
        sound = nil
        windows.removeAll()
        placement.removeAll()
        pendingGeometry.removeAll()
        lastVsync.removeAll()
        focusedWindow = nil
        preedit = nil
        textInput = nil
    }

    private func send(_ message: ClientMessage) {
        stream?.send(DisplayFraming.encode(message.frame))
    }

    private func sendHello() {
        state = .authenticating
        send(.hello(token: displayToken, decoders: decoders, displays: displays, videoDecoders: decoders,
                    audioDecoders: playsAudio ? ["opus"] : nil))
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
            case .textInput(let window, let enabled, let purpose):
                textInput = (window, enabled, purpose)
                cursorSerial &+= 1
            case .clipboard(let mime, let data):
                guard mime.hasPrefix("text/plain"), let text = String(data: data, encoding: .utf8) else { continue }
                lastClipboard = text
                onClipboardText?(text)
            case .notification(let id, let app, let summary, let body):
                onNotification?(RemoteNotification(id: id, appName: app, summary: summary, body: body))
            case .pong(let sent):
                let now = Self.monotonicMicros()
                if now >= sent { latencyMs = Double(now - sent) / 1000 }
            case .bye(let reason):
                isReplaced = reason == "replaced"
                fail(Self.describe(bye: reason))
            case .videoCreate(let fields): addVideo(fields.id)
            case .videoUpdate(let fields): updateVideo(fields)
            case .videoDestroy(let id): retireVideo(id, after: 0)
            case .frame, .tile, .videoFrame, .videoPresent, .audio, .unknown, .malformed:
                continue // pictures were routed on the socket's queue; sound and unknown types are not used yet
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
            return fail("The computer's display speaks protocol version \(hello.version); this Caboose speaks \(DisplayProtocol.version).")
        }
        server = hello
        state = .ready
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send(.ping(micros: Self.monotonicMicros())) }
        }
        send(.ping(micros: Self.monotonicMicros()))
        for window in windows.values { applyCapabilities(window, xwayland: nil) }
    }

    private func createWindow(_ fields: WindowFields) {
        guard let pipeline = pipelines[fields.id] else { return }
        let kind = fields.kind ?? .toplevel
        let geometry = fields.geometry ?? CGRect(x: 0, y: 0, width: pipeline.surface.pixelSize.width, height: pipeline.surface.pixelSize.height)
        placement[fields.id] = (kind, fields.parent, geometry)
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
            // An older answer while a newer request is in flight (for up to a second) is skipped;
            // the answer to the request, or anything after that second, is taken.
            let stale = pendingGeometry[fields.id].map { geometry != $0.geometry && CACurrentMediaTime() - $0.at < 1 } ?? false
            if !stale {
                pendingGeometry[fields.id] = nil
                entry.geometry = geometry
            }
        }
        placement[fields.id] = entry
        apply(fields, to: window)
        if fields.geometry != nil || fields.parent != nil { place(window) }
    }

    private func destroyWindow(_ id: Int) {
        for video in windows[id]?.videos ?? [] { removeVideo(video.id) }
        pipelines.remove(id)?.close()
        windows[id] = nil
        placement[id] = nil
        if focusedWindow == id { focusedWindow = nil }
        if textInput?.window == id { textInput = nil }
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

    private func apply(_ fields: WindowFields, to window: RemoteWindow) {
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

    // MARK: Windows

    public func configure(_ window: RemoteWindow, frame: CGRect, state: [String: Bool] = [:]) {
        let rounded = frame.integral
        var geometry = rounded
        if var entry = placement[window.id] {
            if entry.kind != .toplevel, let parent = entry.parent.flatMap({ windows[$0] }) {
                geometry = rounded.offsetBy(dx: -parent.frame.minX, dy: -parent.frame.minY)
            }
            entry.geometry = geometry
            placement[window.id] = entry
        }
        pendingGeometry[window.id] = (geometry, CACurrentMediaTime())
        send(.configure(window: window.id, geometry: geometry, fullscreen: state["fullscreen"], maximized: state["maximized"]))
        if let fullscreen = state["fullscreen"] { window.isFullscreen = fullscreen }
        place(window)
    }

    public func focus(_ window: RemoteWindow?) {
        guard let window else {
            if let focusedWindow { send(.configure(window: focusedWindow, geometry: nil, activated: false)) }
            focusedWindow = nil
            return
        }
        focusedWindow = window.id
        window.raisedAt = Date()
        send(.configure(window: window.id, geometry: nil, activated: true))
    }

    public func close(_ window: RemoteWindow) { send(.close(window: window.id)) }

    /// A keyframe repaints the whole window.
    public func refresh(_ window: RemoteWindow) { send(.requestKeyframe(window: window.id)) }

    public func reconfigure(_ capabilities: ClientCapabilities) {
        displays = [DisplayInfo(capabilities)]
        lastVsync.removeAll()
        send(.displays(displays))
    }

    public func offerClipboard(_ text: String) {
        guard state == .ready, has("clipboard"), text != lastClipboard else { return }
        lastClipboard = text
        send(.clipboard(mime: "text/plain;charset=utf-8", data: Data(text.utf8)))
    }

    // MARK: Pacing

    public func displayWillRefresh(_ display: Int, targetTimestamp: CFTimeInterval) {
        guard state == .ready, has("vsync"), targetTimestamp > 0 else { return }
        let micros = UInt64(targetTimestamp * 1_000_000)
        // Every window view on a screen ticks with the same timestamp; send each refresh once.
        if let last = lastVsync[display], micros < last + 1000 { return }
        lastVsync[display] = micros
        send(.vsync(display: display, micros: micros))
    }

    nonisolated static func monotonicMicros() -> UInt64 { UInt64(CACurrentMediaTime() * 1_000_000) }

    // MARK: Input — positions are in the window's own pixels.

    public func pointerMove(in window: RemoteWindow, to point: CGPoint, modifiers: [String] = []) {
        send(.pointer(window: window.id, x: Double(point.x), y: Double(point.y), buttons: buttons, scroll: nil))
    }

    public func pointerButton(in window: RemoteWindow, button: Int, pressed: Bool, at point: CGPoint, modifiers: [String] = []) {
        let bit = PointerButtons.bit(forXButton: button)
        guard bit != 0 else { return }
        if pressed { buttons |= bit } else { buttons &= ~bit }
        send(.pointer(window: window.id, x: Double(point.x), y: Double(point.y), buttons: buttons, scroll: nil))
    }

    /// Wayland scrolls by any amount, so every swipe is precise.
    public func scroll(in window: RemoteWindow, dx: CGFloat, dy: CGFloat, at point: CGPoint, modifiers: [String] = []) {
        guard dx != 0 || dy != 0 else { return }
        send(.pointer(window: window.id, x: Double(point.x), y: Double(point.y), buttons: buttons,
                      scroll: (Double(dx), Double(dy), true)))
    }

    public func resetScroll() {}

    public func key(_ stroke: KeyStroke, pressed: Bool, in window: RemoteWindow?, extraModifiers: [String] = []) {
        if let window {
            if pressed { echo.keySent(window.id) }
            if focusedWindow != window.id { focus(window) }
        }
        let modifiers = Array(Set(stroke.modifiers + extraModifiers)).sorted()
        send(.key(keysym: stroke.keyval, pressed: pressed, modifiers: modifiers))
    }

    /// Text goes as a text-input-v3 commit; the server types it as keys into apps without one.
    public func type(_ text: String, in window: RemoteWindow?) {
        guard !text.isEmpty else { return }
        prepareText(for: window)
        preedit = nil
        send(.text(commit: text))
    }

    public func edit(_ edits: [TypingBuffer.Edit], in window: RemoteWindow?) {
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
        if !commit.isEmpty { preedit = nil } // a commit ends the composition
        send(.text(commit: commit.isEmpty ? nil : commit, preedit: preedit?.text, cursor: preedit?.cursor,
                   deleteBefore: deleteBefore > 0 ? deleteBefore : nil))
    }

    /// Compose on the server only where the focused app has text-input-v3 enabled; anywhere
    /// else the composition is typed live, so an X11 app still shows it.
    public var composesText: Bool {
        guard has("text-input-v3"), let textInput, textInput.enabled else { return false }
        return focusedWindow == nil || textInput.window == focusedWindow
    }

    public func compose(_ text: String, selection: NSRange, in window: RemoteWindow?) {
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
        guard !points.isEmpty else { return }
        if points.contains(where: { $0.phase == .down }), focusedWindow != window.id { focus(window) }
        send(.touch(window: window.id, points: points))
    }

    public func pencil(_ sample: PencilSample, in window: RemoteWindow) {
        if sample.phase == .down, focusedWindow != window.id { focus(window) }
        send(.pencil(window: window.id, sample))
    }

    // MARK: Text focus

    public var cursorIsText: Bool? {
        if has("text-input-v3"), let textInput, focusedWindow == nil || textInput.window == focusedWindow {
            return textInput.enabled
        }
        guard let cursorName else { return nil }
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
    private let clock: MediaClock
    private let sound: SoundPlayer?
    private let echo: EchoMeter
    private let retire: @Sendable (Int, UInt64) -> Void
    private let makeDecoder: (DisplayCodec) -> PictureDecoder
    private let send: @Sendable (ClientMessage) -> Void

    init(pipelines: FramePipelineRegistry, videos: VideoRegistry, clock: MediaClock, sound: SoundPlayer?, echo: EchoMeter,
         makeDecoder: @escaping (DisplayCodec) -> PictureDecoder, retire: @escaping @Sendable (Int, UInt64) -> Void,
         send: @escaping @Sendable (ClientMessage) -> Void) {
        self.retire = retire
        self.pipelines = pipelines
        self.videos = videos
        self.clock = clock
        self.sound = sound
        self.echo = echo
        self.makeDecoder = makeDecoder
        self.send = send
    }

    /// Everything that is not a picture, for the main actor.
    func receive(_ data: Data) throws -> [ServerMessage] {
        var others: [ServerMessage] = []
        for frame in try parser.append(data) {
            let message = ServerMessage(frame)
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
                sound?.play(packet)
            case .videoDestroy(let id):
                // The server repainted the region into the window just before; the video goes once
                // that picture is applied (and the view has shown it), never before.
                guard let window = videos[id]?.window, let pipeline = pipelines[window] else {
                    retire(id, 0)
                    continue
                }
                let retire = retire
                pipeline.whenApplied { generation in retire(id, generation) }
            case .videoCreate(let fields):
                // Made here, like a window's pipeline, because its first picture follows at once.
                if videos[fields.id] == nil, let video = RemoteVideo(fields, clock: clock, send: send) { videos[fields.id] = video }
                others.append(message)
            case .windowCreate(let fields):
                if pipelines[fields.id] == nil {
                    let size = fields.geometry?.size ?? CGSize(width: 1, height: 1)
                    pipelines[fields.id] = FramePipeline(windowID: fields.id, width: max(1, Int(size.width)), height: max(1, Int(size.height)),
                                                         makeDecoder: makeDecoder, send: send)
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

extension DisplayInfo {
    /// The screen the server lays windows out for, as the Xpra client describes it too.
    public init(_ capabilities: ClientCapabilities, id: Int = 0) {
        self.init(id: id, width: capabilities.desktopWidth, height: capabilities.desktopHeight,
                  scale: Double(capabilities.dpi) / 96, refreshHz: Double(capabilities.refreshRate), hdr: false)
    }
}
