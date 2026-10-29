import CoreGraphics
import Foundation
import Testing
@testable import CabooseKit

/// Replays the compositor's golden vectors (guest/display/vectors, docs/display.md): every
/// message decodes to its fields, re-encodes to the same bytes, and parses into the typed
/// message the session acts on; every client message the app sends encodes byte for byte.
@Suite struct DisplayVectorTests {
    struct Message {
        var direction: String
        var type: String?
        var typeID: UInt8
        var fields: CBOR?
        var payload: Data?
        var canonicalPayload: Data?
    }

    struct Vector {
        var name: String
        var wire: Data
        var messages: [Message]
    }

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../../../guest/display/vectors").standardized

    static var names: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func vector(_ name: String) throws -> Vector {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("\(name).json"))) as! [String: Any]
        let wire = try Data(contentsOf: directory.appendingPathComponent("\(name).bin"))
        #expect(wire == hex(json["hex"] as! String), "\(name): .bin and hex disagree")
        let messages = (json["messages"] as! [[String: Any]]).map { entry in
            Message(direction: entry["direction"] as! String, type: entry["type"] as? String,
                    typeID: UInt8(entry["type_id"] as! Int), fields: entry["fields"].map(cbor),
                    payload: (entry["payload_hex"] as? String).map(hex),
                    canonicalPayload: (entry["canonical_payload_hex"] as? String).map(hex))
        }
        return Vector(name: name, wire: wire, messages: messages)
    }

    static func hex(_ string: String) -> Data {
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    /// The vectors' typed JSON: `{"$bytes": hex}`, `{"$float": n}`, and plain JSON otherwise.
    static func cbor(_ json: Any) -> CBOR {
        switch json {
        case let dict as [String: Any]:
            if dict.count == 1, let bytes = dict["$bytes"] as? String { return .bytes(hex(bytes)) }
            if dict.count == 1, let float = dict["$float"] as? NSNumber { return .double(float.doubleValue) }
            return .map(dict.map { (.text($0.key), cbor($0.value)) })
        case let array as [Any]:
            return .array(array.map(cbor))
        case let string as String:
            return .text(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CBOR(number.intValue)
        default:
            return .null
        }
    }

    /// Equal as CBOR data: maps compare without regard to key order.
    static func same(_ a: CBOR, _ b: CBOR) -> Bool {
        switch (a, b) {
        case (.map(let x), .map(let y)):
            guard x.count == y.count else { return false }
            return x.allSatisfy { pair in y.contains { same($0.0, pair.0) && same($0.1, pair.1) } }
        case (.array(let x), .array(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { same($0, $1) }
        default:
            return a == b
        }
    }

    @Test func everyVectorIsPresent() {
        #expect(Self.names.count >= 40, "guest/display/vectors is missing or incomplete")
    }

    @Test(arguments: names)
    func decodesAndReencodes(name: String) throws {
        let vector = try Self.vector(name)
        var parser = DisplayFrameParser()
        let frames = try parser.append(vector.wire)
        #expect(frames.count == vector.messages.count, "\(name)")
        var offset = 0
        for (frame, message) in zip(frames, vector.messages) {
            #expect(frame.type == message.typeID, "\(name)")
            let length = Int(vector.wire[offset + 1]) | Int(vector.wire[offset + 2]) << 8 | Int(vector.wire[offset + 3]) << 16
                | Int(vector.wire[offset + 4]) << 24
            let payload = vector.wire.subdata(in: offset + 5 ..< offset + 5 + length)
            offset += 5 + length
            if let fields = message.fields {
                // A liberal payload may carry keys v0 does not know; decoders ignore them.
                var body = frame.body
                if message.canonicalPayload != nil, case .map(let pairs) = body, let known = fields.pairs?.map(\.0) {
                    body = .map(pairs.filter { pair in known.contains(pair.0) })
                }
                #expect(Self.same(body, fields), "\(name) \(message.type ?? "?"): decoded \(frame.body)")
                // Canonical: the bytes are exactly the encoding of the fields. Liberal: they decode
                // to the fields, which encode to the canonical payload.
                let expected = message.canonicalPayload ?? payload
                #expect(fields.encoded() == expected, "\(name): encoding of the fields")
                #expect(body.encoded() == expected, "\(name): re-encoding")
            }
            if message.type == nil {
                #expect(DisplayProtocol.ServerType(rawValue: frame.type) == nil && DisplayProtocol.ClientType(rawValue: frame.type) == nil)
            }
        }
        #expect(offset == vector.wire.count)
    }

    @Test(arguments: names)
    func serverMessagesParse(name: String) throws {
        let vector = try Self.vector(name)
        var parser = DisplayFrameParser()
        for (frame, message) in zip(try parser.append(vector.wire), vector.messages) where message.direction == "server" {
            switch ServerMessage(frame) {
            case .malformed(let type): Issue.record("\(name): type 0x\(String(type, radix: 16)) did not parse")
            case .unknown: #expect(message.type == nil, "\(name)")
            default: #expect(message.type != nil, "\(name)")
            }
        }
    }

    @Test func streamSplitAtEveryByteParsesTheSame() throws {
        let wire = try Self.names.map { try Self.vector($0) }
            .filter { $0.messages.allSatisfy { $0.direction == "server" } }
            .reduce(Data()) { $0 + $1.wire }
        var whole = DisplayFrameParser()
        let expected = try whole.append(wire)
        var split = DisplayFrameParser()
        var frames: [DisplayFrame] = []
        var index = wire.startIndex
        while index < wire.endIndex {
            let end = min(wire.endIndex, index + 7)
            frames += try split.append(wire.subdata(in: index ..< end))
            index = end
        }
        #expect(frames.count == expected.count)
        #expect(zip(frames, expected).allSatisfy { $0.type == $1.type && $0.body == $1.body })
    }

    // MARK: Typed server messages

    private func server(_ name: String) throws -> [ServerMessage] {
        var parser = DisplayFrameParser()
        return try parser.append(try Self.vector(name).wire).map(ServerMessage.init)
    }

    @Test func serverHello() throws {
        guard case .hello(let hello) = try server("server-hello").first else { Issue.record("not a hello"); return }
        #expect(hello.version == 0)
        #expect(hello.displays == [1, 2])
        #expect(hello.encoders == ["hevc", "h264"])
        #expect(hello.features == ["vsync", "ack", "touch", "text-input-v3", "cursor-named", "xwayland"])
        #expect(hello.epoch == nil)
        guard case .hello(let epoch) = try server("server-hello-epoch").first else { Issue.record("not a hello"); return }
        #expect(epoch.epoch == "5f3a9c01d2e4b678" && epoch.displays == [1] && epoch.features == ["vsync", "ack"])
    }

    /// An epoch that is not short text cannot prove anything, so it reads as absent.
    @Test func invalidEpochIsAbsent() {
        for value: CBOR in [.unsigned(7), .text(""), .text(String(repeating: "e", count: 65)), .bytes(Data([1, 2]))] {
            #expect(ServerHello(.map([(.text("version"), .unsigned(0)), (.text("epoch"), value)])).epoch == nil)
        }
        #expect(ServerHello(.map([(.text("version"), .unsigned(0)), (.text("epoch"), .text("ab"))])).epoch == "ab")
    }

    @Test func windows() throws {
        guard case .windowCreate(let popup) = try server("window-create-popup").first else { Issue.record("popup"); return }
        #expect(popup.id == 9 && popup.parent == 7 && popup.kind == .popup && popup.appID == "chromium")
        #expect(popup.geometry == CGRect(x: 24, y: -310, width: 480, height: 300))
        #expect(popup.xwayland == false && popup.alpha == false && popup.display == 1)

        guard case .windowCreate(let xterm) = try server("window-create-xwayland").first else { Issue.record("xterm"); return }
        #expect(xterm.xwayland == true && xterm.fullscreen == true && xterm.title == "xterm")
        #expect(xterm.minimumSize == CGSize(width: 10, height: 17) && xterm.maximumSize == CGSize(width: 32767, height: 32767))

        guard case .windowCreate(let toplevel) = try server("window-create-toplevel").first else { Issue.record("toplevel"); return }
        #expect(toplevel.icon?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        guard case .windowUpdate(let moved) = try server("window-update-geometry").first else { Issue.record("update"); return }
        #expect(moved.geometry == CGRect(x: 100, y: 80, width: 1600, height: 900) && moved.fullscreen == false && moved.title == nil)

        guard case .windowUpdate(let liberal) = try server("liberal-window-update").first else { Issue.record("liberal"); return }
        #expect(liberal.id == 7 && liberal.title == "x")
    }

    @Test func pictures() throws {
        guard case .frame(let frame) = try server("frame-hevc-keyframe-scaled").first else { Issue.record("frame"); return }
        #expect(frame.window == 12 && frame.codec == .hevc && frame.keyframe && frame.ptsMicros == 4_294_967_296)
        #expect(frame.rect == CGRect(x: 0, y: 0, width: 124, height: 120))
        #expect(frame.crop == CGRect(x: 0, y: 0, width: 62, height: 60))
        guard case .tile(let tile) = try server("tile-png").first else { Issue.record("tile"); return }
        #expect(tile.window == 7 && tile.format == "png")
    }

    @Test func textAndCursor() throws {
        guard case .textInput(let window, let enabled, let purpose, let context) = try server("text-input-enabled").first else { Issue.record("enabled"); return }
        #expect(window == 7 && enabled && purpose == "terminal" && context == nil)
        guard case .textInput(_, let off, let none, _) = try server("text-input-disabled").first else { Issue.record("disabled"); return }
        #expect(!off && none == nil)
        guard case .textInput(_, _, _, let surrounding?) = try server("text-input-surrounding").first else { Issue.record("surrounding"); return }
        #expect(surrounding.text == "Héllo world" && surrounding.cursor == 10 && !surrounding.hasSelection)
        #expect(surrounding.beforeCaret == "Héllo wor")
        guard case .cursorNamed(let name) = try server("cursor-named-text").first else { Issue.record("cursor"); return }
        #expect(name == "text")
        guard case .cursorImage(let id, let image, _) = try server("cursor-image").first else { Issue.record("image"); return }
        #expect(id == 7 && !image.isEmpty)
    }

    @Test func unknownTypesAreSkipped() throws {
        let messages = try server("stream-unknown-skipped")
        #expect(messages.count == 3)
        guard case .cursorNamed("default") = messages[0], case .unknown(0x50) = messages[1], case .windowDestroy(12) = messages[2] else {
            Issue.record("\(messages)"); return
        }
    }

    @Test func otherServerMessages() throws {
        guard case .bye("auth") = try server("bye-auth").first else { Issue.record("bye"); return }
        guard case .pong(98_765_432_100) = try server("pong").first else { Issue.record("pong"); return }
        guard case .clipboard(_, let data) = try server("clipboard-server").first else { Issue.record("clipboard"); return }
        #expect(String(data: data, encoding: .utf8) == "héllo ✓")
        guard case .notification(3, "Chromium", "Download complete", "report.pdf\n2.1 MB") = try server("notification").first else {
            Issue.record("notification"); return
        }
        guard case .audio(let packet) = try server("audio-opus").first else { Issue.record("audio"); return }
        #expect(packet.codec == "opus" && packet.ptsMicros == 1_234_580_000 && packet.channels == 2 && packet.data == Data([0xF8, 0xFF, 0xFE]))
    }

    @Test func games() throws {
        guard case .gameCreate(let game) = try server("game-create").first else { Issue.record("game.create"); return }
        #expect(game == GameDescriptor(id: 1, window: 7, root: ".local/share/caboose/games/powder-toy/web", entry: "index.html",
                                       saves: [GameSave(mount: "/powder", path: ".local/share/The Powder Toy")]))
        guard case .gameCreate(let bare) = try server("game-create-no-saves").first else { Issue.record("no saves"); return }
        #expect(bare == GameDescriptor(id: 2, window: 12, root: "Games/doom", entry: "index.html"))
        guard case .gameDestroy(1) = try server("game-destroy").first else { Issue.record("game.destroy"); return }
    }

    @Test func gpuStreams() throws {
        guard case .gpuCreate(1, 7) = try server("gpu-create").first else { Issue.record("gpu.create"); return }
        guard case .gpuData(1, 0, let data) = try server("gpu-data").first else { Issue.record("gpu.data"); return }
        #expect(data == Data("GFXR".utf8) + Data(count: 12))
        guard case .gpuDestroy(1) = try server("gpu-destroy").first else { Issue.record("gpu.destroy"); return }
    }

    /// A stream's bytes arrive in order once; a repeat from the start (a resent stream) and
    /// anything out of order are dropped, and what arrives before the replay starts is held.
    @Test func aGPUStreamFeedKeepsOrder() {
        let feed = GPUStreamFeed()
        feed.receive(offset: 0, data: Data([1, 2]))
        feed.receive(offset: 5, data: Data([9]))
        final class Received { var chunks: [Data] = [] }
        let received = Received()
        feed.attach { data in received.chunks.append(data) }
        feed.receive(offset: 2, data: Data([3]))
        feed.receive(offset: 0, data: Data([1, 2]))
        #expect(received.chunks == [Data([1, 2]), Data([3])])
        #expect(feed.offset == 3)
        feed.detach()
        feed.receive(offset: 3, data: Data([4]))
        #expect(received.chunks.count == 2)
    }

    /// A game.create without its window, root or entry cannot be run; a save without both
    /// halves is left out.
    @Test func incompleteGamesAreMalformed() {
        let complete: [(CBOR, CBOR)] = [("id", 3), ("window", 7), ("root", "web"), ("entry", "index.html")]
        for missing in ["id", "window", "root", "entry"] {
            let body = CBOR.map(complete.filter { $0.0 != CBOR(missing) })
            guard case .malformed(0x17) = ServerMessage(DisplayFrame(type: 0x17, body: body)) else {
                Issue.record("without \(missing)"); continue
            }
        }
        let saves = CBOR.map(complete + [("saves", [["mount": "/a", "path": "a"], ["mount": "/b"], "c"])])
        guard case .gameCreate(let game) = ServerMessage(DisplayFrame(type: 0x17, body: saves)) else { Issue.record("saves"); return }
        #expect(game.saves == [GameSave(mount: "/a", path: "a")])
        guard case .malformed(0x18) = ServerMessage(DisplayFrame(type: 0x18, body: ["window": 7])) else { Issue.record("destroy"); return }
    }

    /// `wasm` is only ever sent as true; without it the hello is the one older servers know.
    @Test func helloSaysWasmOnlyWhenTrue() {
        let display = DisplayInfo(id: 1, width: 10, height: 10, scale: 1, refreshHz: 60)
        let plain = ClientMessage.hello(token: "t", decoders: [.h264], displays: [display]).frame.body
        #expect(plain["wasm"] == nil)
        #expect(ClientMessage.hello(token: "t", decoders: [.h264], displays: [display], wasm: false).frame.body.encoded() == plain.encoded())
        #expect(ClientMessage.hello(token: "t", decoders: [.h264], displays: [display], wasm: true).frame.body["wasm"] == .bool(true))
    }

    // MARK: Client messages, byte for byte

    static let clientMessages: [String: ClientMessage] = [
        "ack": .ack(window: 7, ptsMicros: 1_234_567_890, decodedMicros: 2150),
        "ack-decode-failed": .ack(window: 7, ptsMicros: 1_234_567_890, decodedMicros: -1),
        "client-hello": .hello(token: "f3a9c1d27e8b4a6f", decoders: [.hevc, .av1, .h264], displays: [
            DisplayInfo(id: 1, width: 1179, height: 2556, scale: 3, refreshHz: 120, hdr: true),
            DisplayInfo(id: 2, width: 3840, height: 2160, scale: 2, refreshHz: 59.94, hdr: false),
        ]),
        "clipboard-client": .clipboard(mime: "text/plain;charset=utf-8", data: Data("copied on the phone".utf8)),
        "close": .close(window: 7),
        "configure": .configure(window: 7, geometry: CGRect(x: 0, y: 0, width: 2556, height: 1179), display: 1,
                                maximized: true, activated: true),
        "displays": .displays([DisplayInfo(id: 1, width: 2556, height: 1179, scale: 3, refreshHz: 120, hdr: true)]),
        "key-shift-a": .key(keysym: 65, pressed: true, modifiers: ["shift"]),
        "liberal-vsync-wide-int": .vsync(display: 1, micros: 1000),
        "pencil-hover": .pencil(window: 7, PencilSample(phase: .hover, x: 300.5, y: 410, pressure: 0, tilt: (12.5, -30), azimuth: 271.25)),
        "ping": .ping(micros: 98_765_432_100),
        "pointer-left-drag": .pointer(window: 7, x: 10.5, y: 20, buttons: 1, scroll: nil),
        "pointer-scroll-precise": .pointer(window: 7, x: 640, y: 480, buttons: 0, scroll: (0, -42.5, true)),
        "request-keyframe": .requestKeyframe(window: 7),
        "text-commit": .text(commit: "naïve café 👍"),
        "text-preedit": .text(commit: nil, preedit: "にほん", cursor: (3, 3)),
        "text-replace": .text(commit: "the ", deleteBefore: 2),
        "touch-two-fingers": .touch(window: 7, points: [
            TouchPoint(slot: 0, phase: .motion, x: 512.5, y: 900.25, force: 0.5, radius: 21),
            TouchPoint(slot: 1, phase: .down, x: 700, y: 1200.75),
        ]),
        "vsync": .vsync(display: 1, micros: 5_000_008_333),
        "client-hello-video": .hello(token: "f3a9c1d27e8b4a6f", decoders: [.hevc, .h264], displays: [
            DisplayInfo(id: 1, width: 1179, height: 2556, scale: 3, refreshHz: 120, hdr: true),
        ], videoDecoders: [.hevc, .h264]),
        "client-hello-audio": .hello(token: "f3a9c1d27e8b4a6f", decoders: [.hevc, .h264], displays: [
            DisplayInfo(id: 1, width: 1179, height: 2556, scale: 3, refreshHz: 120, hdr: true),
        ], videoDecoders: [.hevc, .h264], audioDecoders: ["opus"]),
        "client-hello-gpu": .hello(token: "f3a9c1d27e8b4a6f", decoders: [.hevc, .h264], displays: [
            DisplayInfo(id: 1, width: 1179, height: 2556, scale: 3, refreshHz: 120, hdr: true),
        ], videoDecoders: [.hevc, .h264], audioDecoders: ["opus"], gpu: true),
        "gpu-ack": .gpuAck(id: 1, offset: 65536),
        "client-hello-wasm": .hello(token: "f3a9c1d27e8b4a6f", decoders: [.hevc, .h264], displays: [
            DisplayInfo(id: 1, width: 1179, height: 2556, scale: 3, refreshHz: 120, hdr: true),
        ], videoDecoders: [.hevc, .h264], audioDecoders: ["opus"], wasm: true),
        "video-ack": .videoAck(video: 2, seq: 41),
        "video-keyframe": .videoKeyframe(video: 1),
    ]

    static var clientVectors: [String] {
        names.filter { (try? vector($0).messages.contains { $0.direction == "client" }) == true }
    }

    @Test func everyClientVectorIsCovered() throws {
        #expect(Set(Self.clientVectors).isSubset(of: Set(Self.clientMessages.keys)), "a client vector the app has no message for")
    }

    @Test(arguments: clientVectors)
    func clientMessageEncodesExactly(name: String) throws {
        let vector = try Self.vector(name)
        let message = try #require(Self.clientMessages[name])
        if let canonical = vector.messages.first?.canonicalPayload {
            #expect(message.frame.body.encoded() == canonical, "\(name)")
            #expect(message.frame.type == vector.messages.first?.typeID)
        } else {
            #expect(DisplayFraming.encode(message.frame) == vector.wire, "\(name)")
        }
    }
}
