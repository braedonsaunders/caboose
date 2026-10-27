import CoreGraphics
import Foundation
import ImageIO
import Observation

/// A Linux window as Caboose knows it.
@MainActor @Observable
public final class RemoteWindow: Identifiable {
    public nonisolated let id: Int
    public internal(set) var title: String = ""
    /// WM_CLASS instance and class, e.g. ("xfce4-terminal", "Xfce4-terminal").
    public internal(set) var appClass: (instance: String, name: String)?
    public internal(set) var isOverrideRedirect: Bool
    public internal(set) var transientFor: Int?
    public internal(set) var windowTypes: [String] = []
    public internal(set) var isModal = false
    public internal(set) var hasAlpha = false
    /// Position and size in the server's pixel space.
    public internal(set) var frame: CGRect
    public internal(set) var minimumSize: CGSize?
    public internal(set) var maximumSize: CGSize?
    public internal(set) var icon: CGImage?
    public internal(set) var pid: Int?
    public internal(set) var raisedAt = Date()
    public nonisolated let surface: WindowSurface
    var resizeCounter = 0

    init(id: Int, frame: CGRect, overrideRedirect: Bool, surface: WindowSurface) {
        self.id = id
        self.frame = frame
        self.isOverrideRedirect = overrideRedirect
        self.surface = surface
    }

    /// Popups, menus, tooltips and dialogs belong to a parent window rather than standing alone.
    public var isAuxiliary: Bool {
        isOverrideRedirect || transientFor != nil
            || windowTypes.contains { ["DIALOG", "MENU", "POPUP_MENU", "DROPDOWN_MENU", "TOOLTIP", "UTILITY", "NOTIFICATION", "SPLASH", "COMBO"].contains($0) }
    }

    func apply(metadata: RValue) {
        let meta = metadata.stringKeyed
        if let title = meta["title"]?.string { self.title = title }
        if let parts = meta["class-instance"]?.list, parts.count >= 2,
           let instance = parts[0].string, let name = parts[1].string {
            appClass = (instance, name)
        }
        if let value = meta["transient-for"]?.int { transientFor = value > 0 ? value : nil }
        if let types = meta["window-type"]?.list { windowTypes = types.compactMap(\.string) }
        if let value = meta["modal"]?.bool { isModal = value }
        if let value = meta["has-alpha"]?.bool { hasAlpha = value }
        if let value = meta["override-redirect"]?.bool { isOverrideRedirect = value }
        if let value = meta["pid"]?.int { pid = value }
        if let hints = meta["size-hints"] {
            if let min = hints["minimum-size"]?.list, min.count == 2 {
                minimumSize = CGSize(width: min[0].int ?? 0, height: min[1].int ?? 0)
            }
            if let max = hints["maximum-size"]?.list, max.count == 2 {
                maximumSize = CGSize(width: max[0].int ?? 0, height: max[1].int ?? 0)
            }
        }
    }
}

public struct RemoteNotification: Sendable, Identifiable {
    public var id: Int
    public var appName: String
    public var summary: String
    public var body: String
}

/// One connection to the Xpra server inside the user's computer.
@MainActor @Observable
public final class XpraSession {
    public enum State: Equatable {
        case idle
        case connecting
        case authenticating
        case ready
        case closed(reason: String?)
    }

    public private(set) var state: State = .idle
    public private(set) var windows: [Int: RemoteWindow] = [:]
    public private(set) var serverVersion: String?
    public private(set) var startupComplete = false
    /// Latest server→client latency measured from pings, in milliseconds.
    public private(set) var latencyMs: Double?

    /// Called with text the computer put on its clipboard.
    public var onClipboardText: ((String) -> Void)?
    /// Asked for the phone's clipboard text when the computer pastes.
    public var clipboardProvider: (() -> String?)?
    public var onNotification: ((RemoteNotification) -> Void)?
    public var onNotificationClosed: ((Int) -> Void)?
    public var onBell: (() -> Void)?
    public var onRaise: ((Int) -> Void)?
    public var onOpenURL: ((URL) -> Void)?

    private let url: URL
    private let token: String
    private let password: String
    private var capabilities: ClientCapabilities
    private var transport: XpraTransport?
    private let pipelines = PipelineRegistry()
    private var buttonsDown = Set<Int>()
    private var lastClipboardSent: String?
    private var pingTimer: Timer?

    public init(displayURL: URL, token: String, password: String, capabilities: ClientCapabilities) {
        url = displayURL
        self.token = token
        self.password = password
        self.capabilities = capabilities
    }

    public var desktopSize: CGSize {
        CGSize(width: capabilities.desktopWidth, height: capabilities.desktopHeight)
    }

    // MARK: Connection

    public func connect() {
        guard state == .idle || isClosed else { return }
        state = .connecting
        let pipelines = self.pipelines
        let transport = XpraTransport(url: url, token: token) { [weak self] event in
            switch event {
            case .opened:
                Task { @MainActor in self?.sendHello() }
            case .packets(let packets):
                var others: [XpraPacket] = []
                for packet in packets {
                    // Draws go straight to their window's decode queue, never through the main actor.
                    let packet = PacketNames.normalized(packet)
                    if packet.type == "window-draw", let wid = packet[0]?.int, let pipeline = pipelines[wid] {
                        pipeline.draw(packet)
                    } else {
                        others.append(packet)
                    }
                }
                if !others.isEmpty { Task { @MainActor in self?.handle(others) } }
            case .closed(let error):
                Task { @MainActor in self?.didClose(error) }
            }
        }
        self.transport = transport
        transport.open()
    }

    public func disconnect() {
        transport?.send(XpraPacket("connection-close", ["client disconnected"]))
        transport?.close()
        transport = nil
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
        for wid in windows.keys { pipelines.remove(wid)?.close() }
        windows.removeAll()
    }

    private func sendHello(challengeResponse: String? = nil, clientSalt: String? = nil) {
        transport?.send(XpraPacket("hello", [capabilities.hello(challengeResponse: challengeResponse, clientSalt: clientSalt)]))
    }

    private func send(_ type: String, _ arguments: [RValue]) {
        transport?.send(XpraPacket(type, arguments))
    }

    // MARK: Server packets

    private func handle(_ packets: [XpraPacket]) {
        for packet in packets {
            switch packet.type {
            case "hello": didReceiveHello(packet)
            case "challenge": answerChallenge(packet)
            case "window-create": createWindow(packet)
            case "window-metadata":
                if let wid = packet[0]?.int, let metadata = packet[1] { windows[wid]?.apply(metadata: metadata) }
            case "window-destroy":
                if let wid = packet[0]?.int { destroyWindow(wid) }
            case "window-icon": setIcon(packet)
            case "window-move-resize":
                if let wid = packet[0]?.int { moveResize(wid, x: packet[1]?.int, y: packet[2]?.int, width: packet[3]?.int, height: packet[4]?.int) }
            case "window-resized":
                if let wid = packet[0]?.int { moveResize(wid, x: nil, y: nil, width: packet[1]?.int, height: packet[2]?.int) }
            case "window-raise":
                if let wid = packet[0]?.int { windows[wid]?.raisedAt = Date(); onRaise?(wid) }
            case "window-bell": onBell?()
            case "notification-show": showNotification(packet)
            case "notification-close":
                if let nid = packet[0]?.int { onNotificationClosed?(nid) }
            case "clipboard-data": receiveClipboard(packet)
            case "clipboard-request": answerClipboardRequest(packet)
            case "ping": answerPing(packet)
            case "ping-echo": measureLatency(packet)
            case "startup-complete": startupComplete = true
            case "file-open-url":
                if let text = packet[0]?.string, let target = URL(string: text) { onOpenURL?(target) }
            case "connection-close", "close", "error":
                let reason = packet[0]?.string ?? packet.type
                transport?.close()
                transport = nil
                state = .closed(reason: reason)
            default:
                continue // Feature packets Caboose does not use yet (audio, printing, …).
            }
        }
    }

    private func didReceiveHello(_ packet: XpraPacket) {
        let caps = packet[0] ?? .dict([])
        serverVersion = caps["version"]?.string
        // The server defers its keymap until the client describes its keyboard. Without it,
        // modifiers in key events are ignored (no Shift, so "(" types "9"). The layout equals
        // the server default, so force it to apply.
        send("keyboard-config", [[
            "layout": RValue(capabilities.keyboardLayout),
            "keymap": ["layout": RValue(capabilities.keyboardLayout), "variant": "", "options": ""],
            "modifiers": [],
            "force": true,
        ]])
        state = .ready
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.send("ping", [.int(Int64(Date().timeIntervalSince1970 * 1000))]) }
        }
    }

    private func answerChallenge(_ packet: XpraPacket) {
        state = .authenticating
        guard let salt = packet[0]?.data else { return fail("The computer sent an invalid sign-in challenge.") }
        let digest = packet[2]?.string ?? "hmac+sha256"
        let saltDigest = packet[3]?.string ?? "xor"
        do {
            let answer = try XpraChallenge.respond(password: password, serverSalt: salt, digest: digest, saltDigest: saltDigest)
            sendHello(challengeResponse: answer.response, clientSalt: answer.clientSalt)
        } catch {
            fail("The computer asked for an unsupported sign-in method (\(digest)).")
        }
    }

    private func fail(_ reason: String) {
        transport?.close()
        transport = nil
        state = .closed(reason: reason)
    }

    /// `window-create`: wid, x, y, width, height, metadata, client properties.
    private func createWindow(_ packet: XpraPacket) {
        guard let wid = packet[0]?.int else { return }
        let frame = CGRect(x: packet[1]?.int ?? 0, y: packet[2]?.int ?? 0,
                           width: max(1, packet[3]?.int ?? 1), height: max(1, packet[4]?.int ?? 1))
        let metadata = packet[5] ?? .dict([])
        let overrideRedirect = metadata["override-redirect"]?.bool ?? false
        let transport = self.transport
        let pipeline = DrawPipeline(windowID: wid, width: Int(frame.width), height: Int(frame.height)) { packet in
            transport?.send(packet)
        }
        pipelines[wid] = pipeline
        let window = RemoteWindow(id: wid, frame: frame, overrideRedirect: overrideRedirect, surface: pipeline.surface)
        window.apply(metadata: metadata)
        windows[wid] = window
        if !overrideRedirect {
            send("window-map", [.int(Int64(wid)), .int(Int64(frame.minX)), .int(Int64(frame.minY)),
                                .int(Int64(frame.width)), .int(Int64(frame.height)), .dict([])])
        }
    }

    private func destroyWindow(_ wid: Int) {
        pipelines.remove(wid)?.close()
        windows[wid] = nil
    }

    private func moveResize(_ wid: Int, x: Int?, y: Int?, width: Int?, height: Int?) {
        guard let window = windows[wid] else { return }
        var frame = window.frame
        if let x { frame.origin.x = CGFloat(x) }
        if let y { frame.origin.y = CGFloat(y) }
        if let width, let height, width > 0, height > 0 {
            frame.size = CGSize(width: width, height: height)
            pipelines[wid]?.resize(width: width, height: height)
        }
        window.frame = frame
    }

    /// `window-icon`: wid, width, height, coding, data.
    private func setIcon(_ packet: XpraPacket) {
        guard let wid = packet[0]?.int, packet[3]?.string == "png", let data = packet[4]?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        windows[wid]?.icon = image
    }

    /// `notification-show`: dbus id, nid, app name, replaces nid, app icon, summary, body, timeout, icon, actions, hints.
    private func showNotification(_ packet: XpraPacket) {
        guard let nid = packet[1]?.int else { return }
        onNotification?(RemoteNotification(
            id: nid, appName: packet[2]?.string ?? "", summary: packet[5]?.string ?? "", body: packet[6]?.string ?? ""))
    }

    private func answerPing(_ packet: XpraPacket) {
        let echo = packet[0] ?? .int(0)
        let sid = packet[2] ?? RValue("")
        send("ping_echo", [echo, 0, 0, 0, 0, sid])
    }

    private func measureLatency(_ packet: XpraPacket) {
        guard let sent = packet[0]?.double else { return }
        latencyMs = Date().timeIntervalSince1970 * 1000 - sent
    }

    // MARK: Clipboard

    /// The computer's clipboard changed. Xpra 6 sends `clipboard-token` with positional
    /// fields (selection, targets, target, dtype, dformat, encoding, data, …); newer servers
    /// send `clipboard-data` with { targets, data: { target: [dtype, dformat, encoding, bytes] } }.
    private func receiveClipboard(_ packet: XpraPacket) {
        if packet[1]?.list != nil || packet.arguments.count >= 7 {
            guard let target = packet[2]?.string, target.contains("STRING") || target.contains("text"),
                  let bytes = packet[6]?.data, let text = String(data: bytes, encoding: .utf8) else { return }
            lastClipboardSent = text
            onClipboardText?(text)
            return
        }
        guard let options = packet[1], let items = options["data"]?.pairs else { return }
        for item in items {
            guard let target = item.key.string, target.contains("STRING") || target.contains("text"),
                  let fields = item.value.list, fields.count >= 4,
                  let bytes = fields[3].data, let text = String(data: bytes, encoding: .utf8) else { continue }
            lastClipboardSent = text
            onClipboardText?(text)
            return
        }
    }

    /// `clipboard-request`: request id, selection, target.
    private func answerClipboardRequest(_ packet: XpraPacket) {
        guard let requestID = packet[0] else { return }
        let selection = packet[1] ?? "CLIPBOARD"
        if let text = clipboardProvider?(), !text.isEmpty {
            send("clipboard-contents", [requestID, selection, "UTF8_STRING", 8, "bytes", .bytes(Data(text.utf8))])
        } else {
            send("clipboard-contents-none", [requestID, selection])
        }
    }

    /// Offers the phone's clipboard to the computer, so a paste there gets it.
    public func offerClipboard(_ text: String) {
        guard state == .ready, text != lastClipboardSent else { return }
        lastClipboardSent = text
        // clipboard-token: selection, targets, target, dtype, dformat, wire encoding, data, claim, greedy, synchronous.
        send("clipboard-token", ["CLIPBOARD", ["UTF8_STRING", "text/plain"], "UTF8_STRING", "UTF8_STRING", 8, "bytes",
                                 .bytes(Data(text.utf8)), true, true, true])
    }

    // MARK: Windows

    /// Moves and resizes a window on the server, e.g. to fill the phone.
    public func configure(_ window: RemoteWindow, frame: CGRect) {
        let rounded = frame.integral
        window.resizeCounter += 1
        window.frame = rounded
        pipelines[window.id]?.resize(width: Int(rounded.width), height: Int(rounded.height))
        send("window-configure", [.int(Int64(window.id)), [
            "geometry": [.int(Int64(rounded.minX)), .int(Int64(rounded.minY)), .int(Int64(rounded.width)), .int(Int64(rounded.height))],
            "resize-counter": .int(Int64(window.resizeCounter)),
            "properties": .dict([]),
            "state": .dict([]),
        ]])
    }

    public func focus(_ window: RemoteWindow?) {
        send("window-focus", [.int(Int64(window?.id ?? 0)), []])
    }

    public func close(_ window: RemoteWindow) {
        send("window-close", [.int(Int64(window.id))])
    }

    /// Asks for a full repaint, e.g. after the app returns to the foreground.
    public func refresh(_ window: RemoteWindow) {
        send("window-refresh", [.int(Int64(window.id)), 0, 100, .dict([]), .dict([])])
    }

    public func suspend() { send("suspend", [true, .list(windows.keys.map { .int(Int64($0)) })]) }
    public func resume() { send("resume", [true, .list(windows.keys.map { .int(Int64($0)) })]) }

    // MARK: Input — positions are in the window's own pixel space.

    public func pointerMove(in window: RemoteWindow, to point: CGPoint, modifiers: [String] = []) {
        let (position, props) = pointer(window, point, modifiers)
        send("pointer-motion", [-1, 0, .int(Int64(window.id)), position, props])
    }

    public func pointerButton(in window: RemoteWindow, button: Int, pressed: Bool, at point: CGPoint, modifiers: [String] = []) {
        if pressed { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
        let (position, props) = pointer(window, point, modifiers)
        send("pointer-button", [-1, 0, .int(Int64(window.id)), .int(Int64(button)), .bool(pressed), position, props])
    }

    /// Precise scrolling; deltas in pixels, positive down/right.
    public func scroll(in window: RemoteWindow, dx: CGFloat, dy: CGFloat, at point: CGPoint, modifiers: [String] = []) {
        let (position, _) = pointer(window, point, modifiers)
        let buttons = RValue.list(buttonsDown.sorted().map { .int(Int64($0)) })
        let mods = RValue.list(modifiers.map { RValue($0) })
        if dy != 0 {
            let distance = Int64((abs(dy) * 1000 / 120).rounded())
            send("pointer-wheel", [.int(Int64(window.id)), .int(dy > 0 ? 5 : 4), .int(distance), position, mods, buttons])
        }
        if dx != 0 {
            let distance = Int64((abs(dx) * 1000 / 120).rounded())
            send("pointer-wheel", [.int(Int64(window.id)), .int(dx > 0 ? 7 : 6), .int(distance), position, mods, buttons])
        }
    }

    public func key(_ stroke: KeyStroke, pressed: Bool, in window: RemoteWindow?, extraModifiers: [String] = []) {
        let modifiers = Array(Set(stroke.modifiers + extraModifiers)).sorted()
        send("keyboard-event", [.int(Int64(window?.id ?? 0)), RValue(stroke.name), .bool(pressed), [
            "modifiers": .list(modifiers.map { RValue($0) }),
            "keyval": .int(Int64(stroke.keyval)),
            "string": RValue(stroke.string),
            "keycode": 0,
            "group": 0,
        ]])
    }

    /// Types text as key presses — what the iOS keyboard, dictation and paste produce.
    /// Each key carries the modifiers its character needs; the server presses Shift to match.
    public func type(_ text: String, in window: RemoteWindow?) {
        for character in text {
            guard let stroke = Keysyms.stroke(for: character) else { continue }
            key(stroke, pressed: true, in: window)
            key(stroke, pressed: false, in: window)
        }
    }

    private func pointer(_ window: RemoteWindow, _ point: CGPoint, _ modifiers: [String]) -> (RValue, RValue) {
        let local = CGPoint(x: point.x.rounded(), y: point.y.rounded())
        let absolute = CGPoint(x: window.frame.minX + local.x, y: window.frame.minY + local.y)
        let position: RValue = [.int(Int64(max(0, absolute.x))), .int(Int64(max(0, absolute.y)))]
        let props: RValue = [
            "modifiers": .list(modifiers.map { RValue($0) }),
            "buttons": .list(buttonsDown.sorted().map { .int(Int64($0)) }),
            "window-position": [.int(Int64(local.x)), .int(Int64(local.y))],
        ]
        return (position, props)
    }
}

/// Xpra renamed most packets across releases (`draw` → `window-draw`, `new-window` →
/// `window-create`, …) and servers send either dialect depending on version. Incoming
/// packets are normalised to the modern names so one set of handlers serves both.
enum PacketNames {
    static let modern: [String: String] = [
        "new-window": "window-create",
        "new-override-redirect": "window-create",
        "draw": "window-draw",
        "lost-window": "window-destroy",
        "raise-window": "window-raise",
        "bell": "window-bell",
        "notify_show": "notification-show",
        "notify_close": "notification-close",
        "cursor": "cursor-data",
        "disconnect": "connection-close",
        "desktop_size": "display-resized",
        "clipboard-token": "clipboard-data",
        "set-clipboard-enabled": "clipboard-status",
        "ping_echo": "ping-echo",
        "send-file": "file-send",
        "open-url": "file-open-url",
        "startup_complete": "startup-complete",
    ]

    static func normalized(_ packet: XpraPacket) -> XpraPacket {
        guard let name = modern[packet.type] else { return packet }
        var renamed = packet
        renamed.type = name
        if packet.type == "new-override-redirect", case .dict(var pairs)? = renamed[5] {
            // Legacy servers signal override-redirect by packet name, not metadata.
            pairs.append(RPair("override-redirect", true))
            renamed.arguments[5] = .dict(pairs)
        }
        return renamed
    }
}

/// Window id → draw pipeline, readable from the transport queue.
final class PipelineRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pipelines: [Int: DrawPipeline] = [:]

    subscript(wid: Int) -> DrawPipeline? {
        get { lock.lock(); defer { lock.unlock() }; return pipelines[wid] }
        set { lock.lock(); pipelines[wid] = newValue; lock.unlock() }
    }

    @discardableResult func remove(_ wid: Int) -> DrawPipeline? {
        lock.lock(); defer { lock.unlock() }
        return pipelines.removeValue(forKey: wid)
    }
}
