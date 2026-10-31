import CoreGraphics
import Foundation

/// Caboose Display Protocol v0 messages (docs/display.md). Server → client types are
/// 0x01–0x7F and client → server 0x81–0xFF. Coordinates are display pixels: toplevel
/// geometry from its display's origin, popup and dialog geometry from the parent's.
public enum DisplayProtocol {
    public static let version = 0

    public enum ServerType: UInt8, Sendable {
        case hello = 0x01
        case windowCreate = 0x02
        case windowUpdate = 0x03
        case windowDestroy = 0x04
        case frame = 0x10
        case tile = 0x11
        // Video streams (docs/display.md "Video streams").
        case videoCreate = 0x12
        case videoFrame = 0x13
        case videoUpdate = 0x14
        case videoDestroy = 0x15
        case videoPresent = 0x16
        // Game handoff (docs/game-handoff.md).
        case gameCreate = 0x17
        case gameDestroy = 0x18
        // GPU streams (docs/gpu-stream.md).
        case gpuCreate = 0x19
        case gpuData = 0x1A
        case gpuDestroy = 0x1B
        case webviewCreate = 0x1C
        case webviewDestroy = 0x1D
        case cursor = 0x20
        case cursorNamed = 0x21
        case textInput = 0x22
        // Toolkit scroll reports (docs/display.md, "Scroll reports").
        case scrollTree = 0x23
        case clipboard = 0x30
        case notification = 0x31
        case audio = 0x40
        // The phone's hardware as devices (docs/devices.md).
        case deviceStatus = 0x60
        case deviceOpen = 0x61
        case deviceClose = 0x62
        case deviceRumble = 0x63
        case deviceKeyframe = 0x64
        case pong = 0x7E
        case bye = 0x7F
    }

    public enum ClientType: UInt8, Sendable {
        case hello = 0x81
        case vsync = 0x82
        case ack = 0x83
        case configure = 0x84
        case close = 0x85
        case requestKeyframe = 0x86
        case displays = 0x87
        case videoAck = 0x88
        case videoKeyframe = 0x89
        case touch = 0x90
        case pencil = 0x91
        case pointer = 0x92
        case key = 0x93
        case text = 0x94
        case scrollTarget = 0x95
        case gpuAck = 0x96
        case gameDecline = 0x97
        case webviewDecline = 0x98
        case clipboard = 0xA0
        case devices = 0xB0
        case deviceCamera = 0xB1
        case deviceDepth = 0xB2
        case deviceAudio = 0xB3
        case deviceMotion = 0xB4
        case deviceGamepad = 0xB5
        case deviceButton = 0xB6
        case deviceBattery = 0xB7
        case deviceError = 0xB8
        case ping = 0xFE
    }
}

/// A screen the client shows windows on, in its own pixels.
public struct DisplayInfo: Equatable, Sendable {
    public var id: Int
    public var width: Int
    public var height: Int
    public var scale: Double
    public var refreshHz: Double
    public var hdr: Bool

    public init(id: Int, width: Int, height: Int, scale: Double, refreshHz: Double, hdr: Bool = false) {
        self.id = id
        self.width = width
        self.height = height
        self.scale = scale
        self.refreshHz = refreshHz
        self.hdr = hdr
    }

    var cbor: CBOR {
        ["id": CBOR(id), "width": CBOR(width), "height": CBOR(height), "scale": CBOR(scale),
         "refresh_hz": CBOR(refreshHz), "hdr": CBOR(hdr)]
    }
}

// MARK: Server → client

public enum WindowKind: String, Sendable {
    case toplevel, popup, dialog
}

/// The fields of `window.create`, or the changed ones of `window.update`.
public struct WindowFields: Equatable, Sendable {
    public var id: Int
    public var parent: Int?
    public var kind: WindowKind?
    public var title: String?
    public var appID: String?
    public var icon: Data?
    public var geometry: CGRect?
    public var minimumSize: CGSize?
    public var maximumSize: CGSize?
    public var fullscreen: Bool?
    public var display: Int?
    public var xwayland: Bool?
    public var alpha: Bool?
    /// How far the window's pictures extend right of and below `geometry`, while an
    /// overscan the client asked for applies; `[0, 0]` when it ends.
    public var overscan: CGSize?

    public init(id: Int) { self.id = id }

    init?(_ body: CBOR) {
        guard let id = body["id"]?.int else { return nil }
        self.id = id
        parent = body["parent"]?.int
        kind = body["kind"]?.string.flatMap(WindowKind.init(rawValue:))
        title = body["title"]?.string
        appID = body["app_id"]?.string
        icon = body["icon"]?.data
        geometry = body["geometry"].flatMap(Self.rect)
        minimumSize = body["min"].flatMap(Self.size)
        maximumSize = body["max"].flatMap(Self.size)
        fullscreen = body["fullscreen"]?.bool
        display = body["display"]?.int
        xwayland = body["xwayland"]?.bool
        alpha = body["alpha"]?.bool
        overscan = body["overscan"].flatMap(Self.size)
    }

    static func rect(_ value: CBOR) -> CGRect? {
        guard let v = value.ints, v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static func size(_ value: CBOR) -> CGSize? {
        guard let v = value.ints, v.count == 2 else { return nil }
        return CGSize(width: v[0], height: v[1])
    }
}

public enum DisplayCodec: String, Sendable, CaseIterable {
    case hevc, av1, h264
}

/// One encoded picture of one window. `rect` is where it lands in the window (window-local
/// display pixels); `crop` is the visible part of the decoded picture, without encoder padding.
public struct EncodedFrame: Sendable {
    public var window: Int
    public var codec: DisplayCodec
    public var keyframe: Bool
    public var ptsMicros: UInt64
    public var rect: CGRect
    public var crop: CGRect
    public var data: Data

    public init(window: Int, codec: DisplayCodec, keyframe: Bool, ptsMicros: UInt64, rect: CGRect, crop: CGRect, data: Data) {
        self.window = window
        self.codec = codec
        self.keyframe = keyframe
        self.ptsMicros = ptsMicros
        self.rect = rect
        self.crop = crop
        self.data = data
    }

    init?(_ body: CBOR) {
        guard let window = body["id"]?.int, let codec = body["codec"]?.string.flatMap(DisplayCodec.init(rawValue:)),
              let pts = body["pts_us"]?.uint64, let rect = body["rect"].flatMap(WindowFields.rect),
              let data = body["data"]?.data else { return nil }
        self.window = window
        self.codec = codec
        keyframe = body["keyframe"]?.bool ?? false
        ptsMicros = pts
        self.rect = rect
        crop = body["crop"].flatMap(WindowFields.rect) ?? CGRect(origin: .zero, size: rect.size)
        self.data = data
    }
}

/// A lossless refresh of static content.
public struct LosslessTile: Sendable {
    public var window: Int
    public var rect: CGRect
    public var format: String
    public var data: Data

    init?(_ body: CBOR) {
        guard let window = body["id"]?.int, let rect = body["rect"].flatMap(WindowFields.rect),
              let format = body["format"]?.string, let data = body["data"]?.data else { return nil }
        self.window = window
        self.rect = rect
        self.format = format
        self.data = data
    }
}

/// Where a video stream comes from: the app's own bitstream through the Caboose VA-API driver,
/// a Wayland video subsurface the compositor encodes, or a region detected as moving.
public enum VideoSource: String, Sendable {
    case passthrough, surface, motion

    /// Live streams are shown as they decode; an app's own stream when the app presents a frame.
    public var isLive: Bool { self != .passthrough }
}

/// H.273 colour description of a video stream, e.g. 9/16/9 for BT.2020 PQ.
public struct VideoColor: Equatable, Sendable {
    public var primaries: Int
    public var transfer: Int
    public var matrix: Int
    public var fullRange: Bool

    /// PQ or HLG: the stream wants the screen's extended dynamic range.
    public var isHDR: Bool { transfer == 16 || transfer == 18 }

    init?(_ body: CBOR) {
        guard let primaries = body["primaries"]?.int, let transfer = body["transfer"]?.int, let matrix = body["matrix"]?.int else { return nil }
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        fullRange = body["full_range"]?.bool ?? false
    }
}

/// The fields of `video.create`, or the changed ones of `video.update`. `rect` is where the
/// whole picture goes in its window (window-local display pixels, scaled to it), `clip` the
/// part of it that shows, and `z` its order among the window's streams, all above the window.
public struct VideoStreamFields: Sendable {
    public var id: Int
    public var window: Int?
    public var rect: CGRect?
    public var clip: CGRect?
    public var z: Int?
    public var codec: DisplayCodec?
    public var source: VideoSource?
    public var color: VideoColor?
    public var scaled: Bool

    init?(_ body: CBOR) {
        guard let id = body["id"]?.int else { return nil }
        self.id = id
        window = body["window"]?.int
        rect = body["rect"].flatMap(WindowFields.rect)
        clip = body["clip"].flatMap(WindowFields.rect)
        z = body["z"]?.int
        codec = body["codec"]?.string.flatMap(DisplayCodec.init(rawValue:))
        source = body["source"]?.string.flatMap(VideoSource.init(rawValue:))
        color = body["color"].flatMap(VideoColor.init)
        scaled = body["scaled"]?.bool ?? false
    }
}

/// One access unit of a video stream, in decode order (`seq` from 0), in the same in-band
/// format as `frame.data`. Live streams carry `pts_us`; an app's own stream does not, and is
/// shown frame by frame as `video.present` says.
public struct VideoFrame: Sendable {
    public var video: Int
    public var seq: Int
    public var keyframe: Bool
    public var ptsMicros: UInt64?
    public var data: Data

    public init(video: Int, seq: Int, keyframe: Bool, ptsMicros: UInt64? = nil, data: Data) {
        self.video = video
        self.seq = seq
        self.keyframe = keyframe
        self.ptsMicros = ptsMicros
        self.data = data
    }

    init?(_ body: CBOR) {
        guard let video = body["id"]?.int, let seq = body["seq"]?.int, let data = body["data"]?.data else { return nil }
        self.init(video: video, seq: seq, keyframe: body["keyframe"]?.bool ?? false, ptsMicros: body["pts_us"]?.uint64, data: data)
    }
}

/// One packet of the computer's sound: 20 ms of Opus at 48 kHz, stamped with the server clock
/// time of its first sample (the clock pictures are stamped with too).
public struct AudioPacket: Sendable {
    public var codec: String
    public var ptsMicros: UInt64
    public var channels: Int
    public var data: Data

    public init(codec: String = "opus", ptsMicros: UInt64, channels: Int = 2, data: Data) {
        self.codec = codec
        self.ptsMicros = ptsMicros
        self.channels = channels
        self.data = data
    }
}

/// One directory a handed-off game persists through IDBFS: `mount` in the game's Emscripten
/// file system (and the IndexedDB database IDBFS names after it), `path` the directory on the
/// computer that holds it, relative to the home.
public struct GameSave: Equatable, Sendable {
    public var mount: String
    public var path: String

    public init(mount: String, path: String) {
        self.mount = mount
        self.path = path
    }
}

/// `game.create`: window `window` is a game the client runs itself. Its files are served from
/// `root` (relative to the home), its page is `entry` (relative to `root`). Game ids are their
/// own namespace, unique for the server process's lifetime.
public struct GameDescriptor: Equatable, Sendable {
    public var id: Int
    public var window: Int
    public var root: String
    public var entry: String
    public var saves: [GameSave]

    public init(id: Int, window: Int, root: String, entry: String, saves: [GameSave] = []) {
        self.id = id
        self.window = window
        self.root = root
        self.entry = entry
        self.saves = saves
    }

    init?(_ body: CBOR) {
        guard let id = body["id"]?.int, let window = body["window"]?.int, let root = body["root"]?.string,
              let entry = body["entry"]?.string else { return nil }
        self.init(id: id, window: window, root: root, entry: entry, saves: body["saves"]?.array?.compactMap { save in
            guard let mount = save["mount"]?.string, let path = save["path"]?.string else { return nil }
            return GameSave(mount: mount, path: path)
        } ?? [])
    }
}

public struct WebviewDescriptor: Equatable, Sendable {
    public var id: Int
    public var window: Int
    public var app: String
    public var bridge: String
    public var grant: String
    public var root: String
    public var entry: String

    init?(_ body: CBOR) {
        guard let id = body["id"]?.int, let window = body["window"]?.int,
              let app = body["app"]?.string, let bridge = body["bridge"]?.string, let grant = body["grant"]?.string,
              let root = body["root"]?.string, let entry = body["entry"]?.string,
              app.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil,
              bridge.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              grant.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
              root == "Apps/" + app, !entry.isEmpty, !entry.hasPrefix("/"),
              !entry.contains("\0"), !entry.contains("\\"),
              entry.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        self.id = id; self.window = window; self.app = app; self.bridge = bridge; self.grant = grant; self.root = root; self.entry = entry
    }
}

public struct ServerHello: Equatable, Sendable {
    public var version: Int
    public var displays: [Int]
    public var encoders: [String]
    public var features: Set<String>
    /// The server process's epoch: window ids name the same windows only within one. Nil
    /// from a server that sends none, or one that is not 1–64 bytes of text.
    public var epoch: String?
    /// Live GPU service identity for this owner display. Only a nonzero 16-byte
    /// value can authorize matching a GPU surface to one of this display's windows.
    /// This is distinct from the text epoch used for retained ordinary pictures.
    public var gpuLiveEpoch: Data?

    init(_ body: CBOR) {
        version = body["version"]?.int ?? 0
        displays = body["displays"]?.array?.compactMap { $0.int ?? $0["id"]?.int } ?? []
        encoders = body["encoders"]?.array?.compactMap(\.string) ?? []
        features = Set(body["features"]?.array?.compactMap(\.string) ?? [])
        epoch = body["epoch"]?.string.flatMap { (1 ... 64).contains($0.utf8.count) ? $0 : nil }
        gpuLiveEpoch = body["gpu_live_epoch"]?.data.flatMap {
            $0.count == 16 && $0.contains(where: { $0 != 0 }) ? $0 : nil
        }
    }
}

/// A server message, parsed. Anything the client does not know is `.unknown` and skipped.
public enum ServerMessage: Sendable {
    case hello(ServerHello)
    case windowCreate(WindowFields)
    case windowUpdate(WindowFields)
    case windowDestroy(id: Int)
    case frame(EncodedFrame)
    case tile(LosslessTile)
    case cursorImage(window: Int?, image: Data, hotspot: CGPoint)
    case cursorNamed(String)
    case textInput(window: Int, enabled: Bool, purpose: String?, surrounding: SurroundingText?)
    case scrollTree(ScrollTree)
    case clipboard(mime: String, data: Data)
    case notification(id: Int, app: String, summary: String, body: String)
    case audio(AudioPacket)
    case pong(micros: UInt64)
    case bye(reason: String)
    case videoCreate(VideoStreamFields)
    case videoFrame(VideoFrame)
    case videoUpdate(VideoStreamFields)
    case videoDestroy(id: Int)
    /// The app is showing passthrough frame `seq` now.
    case videoPresent(id: Int, seq: Int, ptsMicros: UInt64)
    case webviewCreate(WebviewDescriptor)
    case webviewDestroy(id: Int)
    case gameCreate(GameDescriptor)
    case gameDestroy(id: Int)
    /// Window `window` is drawn on this device from stream `id`, an application's Vulkan calls.
    case gpuCreate(id: Int, window: Int)
    /// The next bytes of stream `id`, `offset` bytes from its start.
    case gpuData(id: Int, offset: UInt64, data: Data)
    /// The stream ended; `reason` says why when the computer could not go on (`spool-limit`).
    case gpuDestroy(id: Int, reason: String?)
    /// What each offered device became in the computer.
    case deviceStatus([DeviceState])
    /// A computer application started using `device`; `rateHz` for motion.
    case deviceOpen(device: String, rateHz: Double?)
    /// The last application using `device` stopped.
    case deviceClose(device: String)
    /// Rumble gamepad `device` (0…1 each) for `ms`; 0 stops it.
    case deviceRumble(device: String, strong: Double, weak: Double, ms: Int)
    /// Send a camera keyframe next.
    case deviceKeyframe(device: String)
    case unknown(type: UInt8)
    /// A known type whose fields are missing or of the wrong kind.
    case malformed(type: UInt8)

    public init(_ frame: DisplayFrame) {
        let body = frame.body
        guard let type = DisplayProtocol.ServerType(rawValue: frame.type) else {
            self = .unknown(type: frame.type)
            return
        }
        let parsed: ServerMessage?
        switch type {
        case .hello: parsed = .hello(ServerHello(body))
        case .windowCreate: parsed = WindowFields(body).map(ServerMessage.windowCreate)
        case .windowUpdate: parsed = WindowFields(body).map(ServerMessage.windowUpdate)
        case .windowDestroy: parsed = body["id"]?.int.map { .windowDestroy(id: $0) }
        case .frame: parsed = EncodedFrame(body).map(ServerMessage.frame)
        case .tile: parsed = LosslessTile(body).map(ServerMessage.tile)
        case .cursor:
            let hotspot = body["hotspot"]?.ints.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } ?? .zero
            parsed = body["image"]?.data.map { .cursorImage(window: body["id"]?.int, image: $0, hotspot: hotspot) }
        case .cursorNamed: parsed = body["name"]?.string.map(ServerMessage.cursorNamed)
        case .scrollTree: parsed = ScrollTree(body).map(ServerMessage.scrollTree)
        case .textInput:
            parsed = body["id"]?.int.map {
                .textInput(window: $0, enabled: body["enabled"]?.bool ?? false, purpose: body["purpose"]?.string,
                           surrounding: SurroundingText(text: body["surrounding"]?.string, cursor: body["cursor"]?.int, anchor: body["anchor"]?.int))
            }
        case .clipboard:
            parsed = body["data"]?.data.map { .clipboard(mime: body["mime"]?.string ?? "text/plain;charset=utf-8", data: $0) }
        case .notification:
            parsed = body["id"]?.int.map {
                .notification(id: $0, app: body["app"]?.string ?? "", summary: body["summary"]?.string ?? "", body: body["body"]?.string ?? "")
            }
        case .audio:
            if let codec = body["codec"]?.string, let pts = body["pts_us"]?.uint64, let data = body["data"]?.data {
                parsed = .audio(AudioPacket(codec: codec, ptsMicros: pts, channels: body["channels"]?.int ?? 2, data: data))
            } else {
                parsed = nil
            }
        case .pong: parsed = body["t_us"]?.uint64.map { .pong(micros: $0) }
        case .bye: parsed = .bye(reason: body["reason"]?.string ?? "")
        case .videoCreate:
            let fields = VideoStreamFields(body)
            parsed = fields.flatMap { $0.window != nil && $0.rect != nil && $0.codec != nil ? .videoCreate($0) : nil }
        case .videoFrame: parsed = VideoFrame(body).map(ServerMessage.videoFrame)
        case .videoUpdate: parsed = VideoStreamFields(body).map(ServerMessage.videoUpdate)
        case .videoDestroy: parsed = body["id"]?.int.map { .videoDestroy(id: $0) }
        case .videoPresent:
            if let id = body["id"]?.int, let seq = body["seq"]?.int, let pts = body["pts_us"]?.uint64 {
                parsed = .videoPresent(id: id, seq: seq, ptsMicros: pts)
            } else {
                parsed = nil
            }
        case .webviewCreate: parsed = WebviewDescriptor(body).map(ServerMessage.webviewCreate)
        case .webviewDestroy: parsed = body["id"]?.int.map { .webviewDestroy(id: $0) }
        case .gameCreate: parsed = GameDescriptor(body).map(ServerMessage.gameCreate)
        case .gameDestroy: parsed = body["id"]?.int.map { .gameDestroy(id: $0) }
        case .gpuCreate:
            if let id = body["id"]?.int, let window = body["window"]?.int { parsed = .gpuCreate(id: id, window: window) } else { parsed = nil }
        case .gpuData:
            if let id = body["id"]?.int, let offset = body["offset"]?.uint64, let data = body["data"]?.data {
                parsed = .gpuData(id: id, offset: offset, data: data)
            } else {
                parsed = nil
            }
        case .gpuDestroy: parsed = body["id"]?.int.map { .gpuDestroy(id: $0, reason: body["reason"]?.string) }
        case .deviceStatus: parsed = body["devices"]?.array.map { .deviceStatus($0.compactMap(DeviceState.init)) }
        case .deviceOpen: parsed = body["device"]?.string.map { .deviceOpen(device: $0, rateHz: body["rate_hz"]?.double) }
        case .deviceClose: parsed = body["device"]?.string.map { .deviceClose(device: $0) }
        case .deviceRumble:
            if let device = body["device"]?.string, let strong = body["strong"]?.double, let weak = body["weak"]?.double, let ms = body["ms"]?.int {
                parsed = .deviceRumble(device: device, strong: strong, weak: weak, ms: ms)
            } else {
                parsed = nil
            }
        case .deviceKeyframe: parsed = body["device"]?.string.map { .deviceKeyframe(device: $0) }
        }
        self = parsed ?? .malformed(type: frame.type)
    }
}

// MARK: Client → server

public enum TouchPhase: String, Sendable {
    case down, motion, up, cancel
}

public enum PencilPhase: String, Sendable {
    case down, motion, up, cancel, hover, leave
}

/// One finger in a `touch` message, at window-local display pixels.
public struct TouchPoint: Equatable, Sendable {
    public var slot: Int
    public var phase: TouchPhase
    public var x: Double
    public var y: Double
    /// 0…1, where the hardware reports force.
    public var force: Double?
    /// In display pixels.
    public var radius: Double?

    public init(slot: Int, phase: TouchPhase, x: Double, y: Double, force: Double? = nil, radius: Double? = nil) {
        self.slot = slot
        self.phase = phase
        self.x = x
        self.y = y
        self.force = force
        self.radius = radius
    }

    var cbor: CBOR {
        var pairs: [(String, CBOR)] = [("slot", CBOR(slot)), ("phase", CBOR(phase.rawValue)), ("x", CBOR(x)), ("y", CBOR(y))]
        if let force { pairs.append(("force", CBOR(force))) }
        if let radius { pairs.append(("radius", CBOR(radius))) }
        return .map(pairs.map { (.text($0.0), $0.1) })
    }
}

/// The application's text around the caret (text-input-v3 surrounding text), with the
/// caret and the selection's other end as UTF-8 byte offsets into it.
public struct SurroundingText: Equatable, Sendable {
    public let text: String
    public let cursor: Int
    public let anchor: Int

    /// Nil unless all three are present and the offsets fall on characters of the text.
    public init?(text: String?, cursor: Int?, anchor: Int?) {
        guard let text, let cursor, let anchor else { return nil }
        let utf8 = text.utf8
        func boundary(_ offset: Int) -> Bool {
            guard (0...utf8.count).contains(offset) else { return false }
            return utf8.index(utf8.startIndex, offsetBy: offset).samePosition(in: text.unicodeScalars) != nil
        }
        guard boundary(cursor), boundary(anchor) else { return nil }
        self.text = text; self.cursor = cursor; self.anchor = anchor
    }

    /// Text is selected in the application.
    public var hasSelection: Bool { cursor != anchor }

    /// The text before the caret.
    public var beforeCaret: String {
        String(decoding: text.utf8.prefix(cursor), as: UTF8.self)
    }
}

/// An Apple Pencil sample, for tablet-v2: pressure 0…1, tilt in degrees from vertical along
/// x and y (−90…90), azimuth in degrees clockwise from the window's +x axis.
public struct PencilSample: Equatable, Sendable {
    public var phase: PencilPhase
    public var x: Double
    public var y: Double
    public var pressure: Double
    public var tilt: (x: Double, y: Double)
    public var azimuth: Double

    public init(phase: PencilPhase, x: Double, y: Double, pressure: Double, tilt: (x: Double, y: Double), azimuth: Double) {
        self.phase = phase
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tilt = tilt
        self.azimuth = azimuth
    }

    public static func == (a: PencilSample, b: PencilSample) -> Bool {
        a.phase == b.phase && a.x == b.x && a.y == b.y && a.pressure == b.pressure
            && a.tilt.x == b.tilt.x && a.tilt.y == b.tilt.y && a.azimuth == b.azimuth
    }

    /// The tablet tilt of a pen held at `altitude` (radians from the screen's plane, π/2
    /// upright) pointing along `azimuth` (radians, the direction from tip to cap on screen).
    public static func tilt(altitude: Double, azimuth: Double) -> (x: Double, y: Double) {
        // The pen's axis from tip to cap; tilt is its angle from vertical in the xz and yz planes.
        let horizontal = cos(altitude), vertical = max(sin(altitude), 1e-6)
        let degrees = 180 / Double.pi
        return (atan2(horizontal * cos(azimuth), vertical) * degrees, atan2(horizontal * sin(azimuth), vertical) * degrees)
    }
}

/// Pointer buttons as the protocol's bitmask, from X button numbers.
public enum PointerButtons {
    public static func bit(forXButton button: Int) -> Int {
        switch button {
        case 1: 1
        case 2: 2
        case 3: 4
        case 8: 8
        case 9: 16
        default: 0
        }
    }
}

public enum ClientMessage: Sendable {
    /// `videoDecoders`: what the client plays as video streams; absent, the server sends none.
    /// `audioDecoders`: the sound codecs the client plays ("opus"); absent, the server sends no sound.
    /// `wasm`: the client runs handed-off games (`"wasm": true`); the key is absent otherwise.
    /// `gpu`: the client renders GPU streams (`"gpu": true`); the key is absent otherwise.
    /// `devices`: the client offers its hardware as devices (docs/devices.md); absent otherwise.
    case hello(token: String, decoders: [DisplayCodec], displays: [DisplayInfo], videoDecoders: [DisplayCodec]? = nil,
               audioDecoders: [String]? = nil, wasm: Bool = false, gpu: Bool = false, scaledMotion: Bool = false, webview: Bool = false,
               devices: Bool = false, scroll: Bool = false)
    case vsync(display: Int, micros: UInt64)
    case ack(window: Int, ptsMicros: UInt64, decodedMicros: Int)
    case configure(window: Int, geometry: CGRect?, display: Int? = nil, fullscreen: Bool? = nil,
                   maximized: Bool? = nil, activated: Bool? = nil, overscan: CGSize? = nil)
    case close(window: Int)
    case requestKeyframe(window: Int)
    case displays([DisplayInfo])
    case touch(window: Int, points: [TouchPoint])
    case pencil(window: Int, PencilSample)
    /// `scrollSeq`: the window's input sequence number for the scroll (docs/display.md,
    /// "Input sequencing").
    case pointer(window: Int, x: Double, y: Double, buttons: Int, scroll: (dx: Double, dy: Double, precise: Bool)?,
                 scrollSeq: UInt64? = nil)
    /// Scroll a reported scroller by `delta` content pixels, exactly, as input `seq`.
    case scrollTarget(window: Int, scroller: Int, seq: UInt64, delta: CGPoint)
    case key(keysym: Int, pressed: Bool, modifiers: [String])
    case text(commit: String?, preedit: String? = nil, cursor: (Int, Int)? = nil, deleteBefore: Int? = nil, deleteAfter: Int? = nil)
    case clipboard(mime: String, data: Data)
    case ping(micros: UInt64)
    /// A video frame is decoded and queued for display.
    case videoAck(video: Int, seq: Int)
    /// The client could not decode a video stream; it drops frames until the next keyframe.
    case videoKeyframe(video: Int)
    /// The client has consumed GPU stream `id` up to `offset`.
    case gpuAck(id: Int, offset: UInt64)
    /// Game `id` cannot run on this device, and why (docs/game-handoff.md, "Declining"). The
    /// reason is cut to `GameDecline.reasonLimit` UTF-8 bytes at a character boundary.
    case gameDecline(id: Int, reason: String)
    case webviewDecline(id: Int, reason: String)
    /// The complete set of devices the phone offers now.
    case devices([DeviceDescriptor])
    /// One H.264 access unit of a camera, Annex-B, with SPS and PPS on keyframes.
    case deviceCamera(device: String, seq: UInt64, keyframe: Bool, micros: UInt64, data: Data)
    /// `width × height` little-endian u16 distances in millimetres, row by row.
    case deviceDepth(device: String, micros: UInt64, width: Int, height: Int, data: Data)
    /// One 20 ms Opus packet, 48 kHz mono.
    case deviceAudio(device: String, micros: UInt64, data: Data)
    case deviceMotion(device: String, samples: [MotionSample])
    case deviceGamepad(device: String, GamepadReport)
    case deviceButton(device: String, key: DeviceKey, pressed: Bool)
    case deviceBattery(device: String, BatteryReport)
    /// The phone cannot run a device it was asked to open; the reason is cut to 200 UTF-8 bytes.
    case deviceError(device: String, reason: String)

    public var frame: DisplayFrame {
        typealias T = DisplayProtocol.ClientType
        func map(_ pairs: [(String, CBOR?)]) -> CBOR {
            .map(pairs.compactMap { pair in pair.1.map { (.text(pair.0), $0) } })
        }
        func rect(_ r: CGRect) -> CBOR {
            [CBOR(Int(r.minX.rounded())), CBOR(Int(r.minY.rounded())), CBOR(Int(r.width.rounded())), CBOR(Int(r.height.rounded()))]
        }
        switch self {
        case .hello(let token, let decoders, let displays, let videoDecoders, let audioDecoders, let wasm, let gpu, let scaledMotion, let webview, let devices, let scroll):
            return DisplayFrame(type: T.hello.rawValue, body: map([
                ("version", CBOR(DisplayProtocol.version)), ("token", CBOR(token)),
                ("decoders", .array(decoders.map { CBOR($0.rawValue) })), ("displays", .array(displays.map(\.cbor))),
                ("video_decoders", videoDecoders.map { .array($0.map { CBOR($0.rawValue) }) }),
                ("audio_decoders", audioDecoders.map { .array($0.map { CBOR($0) }) }),
                ("wasm", wasm ? CBOR(true) : nil),
                ("gpu", gpu ? CBOR(true) : nil),
                ("scaled_motion", scaledMotion ? CBOR(true) : nil),
                ("webview", webview ? CBOR(true) : nil),
                ("devices", devices ? CBOR(true) : nil),
                ("scroll", scroll ? CBOR(true) : nil),
            ]))
        case .devices(let devices):
            return DisplayFrame(type: T.devices.rawValue, body: map([("devices", .array(devices.map(\.cbor)))]))
        case .deviceCamera(let device, let seq, let keyframe, let micros, let data):
            return DisplayFrame(type: T.deviceCamera.rawValue, body: map([
                ("device", CBOR(device)), ("seq", CBOR(seq)), ("keyframe", CBOR(keyframe)), ("t_us", CBOR(micros)), ("data", .bytes(data)),
            ]))
        case .deviceDepth(let device, let micros, let width, let height, let data):
            return DisplayFrame(type: T.deviceDepth.rawValue, body: map([
                ("device", CBOR(device)), ("t_us", CBOR(micros)), ("size", [CBOR(width), CBOR(height)]), ("data", .bytes(data)),
            ]))
        case .deviceAudio(let device, let micros, let data):
            return DisplayFrame(type: T.deviceAudio.rawValue, body: map([("device", CBOR(device)), ("t_us", CBOR(micros)), ("data", .bytes(data))]))
        case .deviceMotion(let device, let samples):
            return DisplayFrame(type: T.deviceMotion.rawValue, body: map([("device", CBOR(device)), ("samples", .array(samples.map(\.cbor)))]))
        case .deviceGamepad(let device, let report):
            return DisplayFrame(type: T.deviceGamepad.rawValue, body: map([
                ("device", CBOR(device)), ("buttons", CBOR(report.buttons)), ("axes", .array(report.axes.map { CBOR($0) })),
            ]))
        case .deviceButton(let device, let key, let pressed):
            return DisplayFrame(type: T.deviceButton.rawValue, body: map([("device", CBOR(device)), ("key", CBOR(key.rawValue)), ("pressed", CBOR(pressed))]))
        case .deviceBattery(let device, let battery):
            return DisplayFrame(type: T.deviceBattery.rawValue, body: map([
                ("device", CBOR(device)), ("level", CBOR(battery.level)), ("charging", CBOR(battery.charging)), ("full", CBOR(battery.full)),
                ("low_power", CBOR(battery.lowPower)), ("thermal", CBOR(battery.thermal.rawValue)),
            ]))
        case .deviceError(let device, let reason):
            return DisplayFrame(type: T.deviceError.rawValue, body: map([("device", CBOR(device)), ("reason", CBOR(GameDecline.bounded(reason)))]))
        case .videoAck(let video, let seq):
            return DisplayFrame(type: T.videoAck.rawValue, body: map([("id", CBOR(video)), ("seq", CBOR(seq))]))
        case .videoKeyframe(let video):
            return DisplayFrame(type: T.videoKeyframe.rawValue, body: map([("id", CBOR(video))]))
        case .gpuAck(let id, let offset):
            return DisplayFrame(type: T.gpuAck.rawValue, body: map([("id", CBOR(id)), ("offset", CBOR(offset))]))
        case .webviewDecline(let id, let reason):
            return DisplayFrame(type: T.webviewDecline.rawValue, body: map([("id", CBOR(id)), ("reason", CBOR(GameDecline.bounded(reason)))]))
        case .gameDecline(let id, let reason):
            return DisplayFrame(type: T.gameDecline.rawValue, body: map([("id", CBOR(id)), ("reason", CBOR(GameDecline.bounded(reason)))]))
        case .vsync(let display, let micros):
            return DisplayFrame(type: T.vsync.rawValue, body: map([("display", CBOR(display)), ("t_us", CBOR(micros))]))
        case .ack(let window, let pts, let decoded):
            return DisplayFrame(type: T.ack.rawValue, body: map([
                ("id", CBOR(window)), ("pts_us", CBOR(pts)), ("decoded_us", CBOR(decoded)),
            ]))
        case .configure(let window, let geometry, let display, let fullscreen, let maximized, let activated, let overscan):
            return DisplayFrame(type: T.configure.rawValue, body: map([
                ("id", CBOR(window)), ("geometry", geometry.map(rect)), ("display", display.map { CBOR($0) }),
                ("fullscreen", fullscreen.map { CBOR($0) }), ("maximized", maximized.map { CBOR($0) }),
                ("activated", activated.map { CBOR($0) }),
                ("overscan", overscan.map { [CBOR(Int($0.width.rounded())), CBOR(Int($0.height.rounded()))] }),
            ]))
        case .close(let window):
            return DisplayFrame(type: T.close.rawValue, body: map([("id", CBOR(window))]))
        case .requestKeyframe(let window):
            return DisplayFrame(type: T.requestKeyframe.rawValue, body: map([("id", CBOR(window))]))
        case .displays(let displays):
            return DisplayFrame(type: T.displays.rawValue, body: map([("displays", .array(displays.map(\.cbor)))]))
        case .touch(let window, let points):
            return DisplayFrame(type: T.touch.rawValue, body: map([("id", CBOR(window)), ("points", .array(points.map(\.cbor)))]))
        case .pencil(let window, let sample):
            return DisplayFrame(type: T.pencil.rawValue, body: map([
                ("id", CBOR(window)), ("phase", CBOR(sample.phase.rawValue)), ("x", CBOR(sample.x)), ("y", CBOR(sample.y)),
                ("pressure", CBOR(sample.pressure)), ("tilt", [CBOR(sample.tilt.x), CBOR(sample.tilt.y)]),
                ("azimuth_deg", CBOR(sample.azimuth)),
            ]))
        case .pointer(let window, let x, let y, let buttons, let scroll, let seq):
            return DisplayFrame(type: T.pointer.rawValue, body: map([
                ("id", CBOR(window)), ("x", CBOR(x)), ("y", CBOR(y)), ("buttons", CBOR(buttons)),
                ("scroll", scroll.map { s in
                    map([("dx", CBOR(s.dx)), ("dy", CBOR(s.dy)), ("precise", CBOR(s.precise)), ("seq", seq.map { CBOR($0) })])
                }),
            ]))
        case .scrollTarget(let window, let scroller, let seq, let delta):
            return DisplayFrame(type: T.scrollTarget.rawValue, body: map([
                ("id", CBOR(window)), ("scroller", CBOR(scroller)), ("seq", CBOR(seq)),
                ("delta", [CBOR(Double(delta.x)), CBOR(Double(delta.y))]),
            ]))
        case .key(let keysym, let pressed, let modifiers):
            return DisplayFrame(type: T.key.rawValue, body: map([
                ("keysym", CBOR(keysym)), ("pressed", CBOR(pressed)), ("mods", .array(modifiers.map { CBOR($0) })),
            ]))
        case .text(let commit, let preedit, let cursor, let deleteBefore, let deleteAfter):
            return DisplayFrame(type: T.text.rawValue, body: map([
                ("commit", commit.map { CBOR($0) }), ("preedit", preedit.map { CBOR($0) }),
                ("cursor", cursor.map { [CBOR($0.0), CBOR($0.1)] }),
                ("delete_before", deleteBefore.map { CBOR($0) }), ("delete_after", deleteAfter.map { CBOR($0) }),
            ]))
        case .clipboard(let mime, let data):
            return DisplayFrame(type: T.clipboard.rawValue, body: map([("mime", CBOR(mime)), ("data", .bytes(data))]))
        case .ping(let micros):
            return DisplayFrame(type: T.ping.rawValue, body: map([("t_us", CBOR(micros))]))
        }
    }
}
