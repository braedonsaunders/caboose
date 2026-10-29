import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import CabooseKit

/// A transport the test drives: it records what the session sends and delivers what the test says.
final class MockStream: ByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var onEvent: (@Sendable (ByteStreamEvent) -> Void)?
    private var written = Data()
    private(set) var closed = false
    private(set) var failure: Error?

    func open(onEvent: @escaping @Sendable (ByteStreamEvent) -> Void) {
        lock.lock(); self.onEvent = onEvent; lock.unlock()
    }

    func send(_ data: Data) { lock.lock(); written.append(data); lock.unlock() }
    func close() { lock.lock(); closed = true; lock.unlock() }
    func fail(_ error: Error) { lock.lock(); failure = error; lock.unlock() }

    func deliver(_ event: ByteStreamEvent) {
        lock.lock(); let handler = onEvent; lock.unlock()
        handler?(event)
    }

    func server(_ messages: [(DisplayProtocol.ServerType, CBOR)]) {
        deliver(.data(messages.reduce(Data()) { $0 + DisplayFraming.encode(DisplayFrame(type: $1.0.rawValue, body: $1.1)) }))
    }

    /// Everything the client sent, parsed, and forgotten.
    func take() -> [DisplayFrame] {
        lock.lock(); let data = written; written = Data(); lock.unlock()
        var parser = DisplayFrameParser()
        return (try? parser.append(data)) ?? []
    }
}

/// A decoder that hands back a solid picture, or fails, as the test says.
final class FakeDecoder: PictureDecoder {
    var fails = false
    private(set) var decoded = 0
    init(fails: Bool = false) { self.fails = fails }

    func decode(_ accessUnit: Data) throws -> CVPixelBuffer? {
        if fails { throw H264DecoderError.decode(-1) }
        decoded += 1
        return Self.picture(width: 8, height: 8)
    }

    func invalidate() {}

    static func picture(width: Int, height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        return buffer!
    }
}

@MainActor @Suite(.serialized) struct CabooseDisplaySessionTests {
    let stream = MockStream()
    let decoder = FakeDecoder()
    let display = DisplayInfo(id: 0, width: 2000, height: 2000, scale: 2, refreshHz: 120)

    func makeSession() -> CabooseDisplaySession {
        let stream = self.stream, decoder = self.decoder
        return CabooseDisplaySession(stream: { stream }, token: "wake-token", displays: [display], decoders: [.hevc, .h264],
                                     makeDecoder: { _ in decoder })
    }

    func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() > deadline { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Connects and completes the handshake with the given server features.
    func ready(features: [String] = ["vsync", "ack", "touch", "text-input-v3", "cursor-named", "xwayland", "clipboard", "pencil"]) async throws -> CabooseDisplaySession {
        let session = makeSession()
        session.connect()
        stream.deliver(.opened)
        try await until("hello") { session.state == .authenticating }
        stream.server([(.hello, ["version": 0, "displays": [0], "encoders": ["hevc", "h264"], "features": .array(features.map { CBOR($0) })])])
        try await until("ready") { session.state == .ready }
        _ = stream.take()
        return session
    }

    func window(_ id: Int, kind: String = "toplevel", parent: Int? = nil, geometry: [Int], xwayland: Bool = false) -> CBOR {
        var pairs: [(CBOR, CBOR)] = [("id", CBOR(id)), ("kind", CBOR(kind)), ("title", "t"), ("app_id", "app"),
                                     ("geometry", .array(geometry.map { CBOR($0) })), ("fullscreen", false), ("xwayland", CBOR(xwayland))]
        if let parent { pairs.append(("parent", CBOR(parent))) }
        return .map(pairs)
    }

    func frame(_ id: Int, pts: Int, keyframe: Bool = true) -> CBOR {
        ["id": CBOR(id), "codec": "hevc", "keyframe": CBOR(keyframe), "pts_us": CBOR(pts), "rect": [0, 0, 8, 8],
         "crop": [0, 0, 8, 8], "data": .bytes(Data([0, 0, 1]))]
    }

    // MARK: Handshake

    @Test func helloCarriesTheTokenDecodersAndDisplays() async throws {
        let session = makeSession()
        session.connect()
        stream.deliver(.opened)
        try await until("hello") { session.state == .authenticating }
        let sent = stream.take()
        #expect(sent.count == 1)
        #expect(sent.first?.type == DisplayProtocol.ClientType.hello.rawValue)
        #expect(sent.first?.body["token"]?.string == "wake-token")
        #expect(sent.first?.body["version"]?.int == 0)
        #expect(sent.first?.body["decoders"]?.array?.compactMap(\.string) == ["hevc", "h264"])
        #expect(sent.first?.body["displays"]?.array?.first?["width"]?.int == 2000)
        #expect(sent.first?.body["displays"]?.array?.first?["refresh_hz"] == .double(120))
    }

    @Test func byeClosesWithAReason() async throws {
        let session = try await ready()
        stream.server([(.bye, ["reason": "auth"])])
        try await until("closed") { if case .closed = session.state { true } else { false } }
        #expect(session.state == .closed(reason: CabooseDisplaySession.describe(bye: "auth")))
        #expect(stream.closed)
    }

    @Test func replacedByAnotherDeviceIsToldApart() async throws {
        let session = try await ready()
        #expect(!session.isReplaced)
        stream.server([(.bye, ["reason": "replaced"])])
        try await until("closed") { if case .closed = session.state { true } else { false } }
        #expect(session.isReplaced)
        #expect(session.state == .closed(reason: "Another device is showing this computer's display."))

        let other = CabooseDisplaySessionTests()
        let shutDown = try await other.ready()
        other.stream.server([(.bye, ["reason": "shutdown"])])
        try await other.until("closed") { if case .closed = shutDown.state { true } else { false } }
        #expect(!shutDown.isReplaced) // only "replaced" holds the app back from reconnecting
    }

    @Test func anotherVersionIsRefused() async throws {
        let session = makeSession()
        session.connect()
        stream.deliver(.opened)
        stream.server([(.hello, ["version": 1, "displays": [0], "encoders": ["hevc"], "features": []])])
        try await until("closed") { if case .closed = session.state { true } else { false } }
    }

    @Test func anOversizedMessageFailsTheStream() async throws {
        _ = try await ready()
        var header = Data([0x10])
        var length = UInt32(DisplayFraming.maximumLength + 1).littleEndian
        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
        stream.deliver(.data(header))
        #expect(stream.failure as? DisplayFramingError == .tooLong(DisplayFraming.maximumLength + 1))
    }

    // MARK: Windows

    @Test func popupsAndDialogsArePlacedFromTheirParent() async throws {
        let session = try await ready()
        stream.server([
            (.windowCreate, window(7, geometry: [100, 80, 1600, 900])),
            (.windowCreate, window(9, kind: "popup", parent: 7, geometry: [24, -310, 480, 300])),
            (.windowCreate, window(10, kind: "dialog", parent: 7, geometry: [400, 200, 800, 500])),
        ])
        try await until("windows") { session.windows.count == 3 }
        let popup = try #require(session.windows[9]), dialog = try #require(session.windows[10])
        #expect(popup.frame == CGRect(x: 124, y: -230, width: 480, height: 300))
        #expect(popup.isOverrideRedirect && popup.isAuxiliary && popup.transientFor == 7)
        #expect(dialog.windowTypes == ["DIALOG"] && !dialog.isOverrideRedirect && dialog.isAuxiliary)
        #expect(session.windows[7]?.isAuxiliary == false)

        // The parent moves: its popups follow.
        stream.server([(.windowUpdate, ["id": 7, "geometry": [0, 0, 1600, 900]])])
        try await until("move") { session.windows[7]?.frame.minX == 0 }
        #expect(popup.frame == CGRect(x: 24, y: -310, width: 480, height: 300))

        // Configuring a dialog sends geometry relative to its parent.
        session.configure(dialog, frame: CGRect(x: 500, y: 300, width: 600, height: 400))
        let configure = try #require(stream.take().first)
        #expect(configure.type == DisplayProtocol.ClientType.configure.rawValue)
        #expect(configure.body["geometry"]?.ints == [500, 300, 600, 400])
        #expect(dialog.frame == CGRect(x: 500, y: 300, width: 600, height: 400))

        stream.server([(.windowDestroy, ["id": 9])])
        try await until("destroyed") { session.windows[9] == nil }
    }

    @Test func nativeWaylandWindowsTakeTouchAndXwaylandOnesDoNot() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100])),
                       (.windowCreate, window(8, geometry: [0, 0, 100, 100], xwayland: true))])
        try await until("windows") { session.windows.count == 2 }
        #expect(session.windows[7]?.acceptsTouch == true)
        #expect(session.windows[8]?.acceptsTouch == false)
        #expect(session.windows[8]?.acceptsPencil == true)
    }

    @Test func touchNeedsTheServerFeature() async throws {
        let session = try await ready(features: ["vsync", "ack"])
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100]))])
        try await until("window") { session.windows[7] != nil }
        #expect(session.windows[7]?.acceptsTouch == false)
        #expect(session.windows[7]?.acceptsPencil == false)
    }

    // MARK: Pictures and flow control

    @Test func everyFrameIsAcked() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 8, 8])), (.frame, frame(7, pts: 1000)), (.frame, frame(7, pts: 2000, keyframe: false))])
        var acks: [DisplayFrame] = []
        try await until("acks") {
            acks += stream.take().filter { $0.type == DisplayProtocol.ClientType.ack.rawValue }
            return acks.count == 2
        }
        #expect(acks.map { $0.body["pts_us"]?.int } == [1000, 2000])
        #expect(acks.allSatisfy { ($0.body["decoded_us"]?.int ?? -1) >= 0 })
        #expect(decoder.decoded == 2)
        try await until("window") { session.windows[7] != nil }
        #expect(session.windows[7]?.surface.generation ?? 0 > 0)
    }

    @Test func resizeMetadataKeepsTheDisplayedPictureCoordinateSpaceUntilReplacement() throws {
        let pipeline = FramePipeline(windowID: 7, width: 8, height: 8, makeDecoder: { _ in FakeDecoder() }, send: { _ in })
        defer { pipeline.close() }
        guard case .frame(let first) = ServerMessage(DisplayFrame(type: DisplayProtocol.ServerType.frame.rawValue, body: frame(7, pts: 1000))) else {
            Issue.record("frame"); return
        }
        pipeline.frame(first)
        pipeline.flush()
        pipeline.resize(width: 16, height: 20)
        pipeline.flush()
        #expect(pipeline.surface.pixelSize == CGSize(width: 8, height: 8))
        let body: CBOR = ["id": 7, "codec": "hevc", "keyframe": false, "pts_us": 2000,
                          "rect": [0, 0, 16, 20], "crop": [0, 0, 8, 8], "data": .bytes(Data([0, 0, 1]))]
        guard case .frame(let replacement) = ServerMessage(DisplayFrame(type: DisplayProtocol.ServerType.frame.rawValue, body: body)) else {
            Issue.record("replacement"); return
        }
        pipeline.frame(replacement)
        pipeline.flush()
        #expect(pipeline.surface.pixelSize == CGSize(width: 16, height: 20))
    }

    @Test func aBrokenStreamAsksForOneKeyframeAndSkipsToIt() async throws {
        _ = try await ready()
        decoder.fails = true
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 8, 8])), (.frame, frame(7, pts: 1000)),
                       (.frame, frame(7, pts: 2000, keyframe: false)), (.frame, frame(7, pts: 3000, keyframe: false))])
        var sent: [DisplayFrame] = []
        try await until("acks") {
            sent += stream.take()
            return sent.filter { $0.type == DisplayProtocol.ClientType.ack.rawValue }.count == 3
        }
        let acks = sent.filter { $0.type == DisplayProtocol.ClientType.ack.rawValue }
        #expect(acks.allSatisfy { $0.body["decoded_us"]?.int == -1 })
        #expect(sent.filter { $0.type == DisplayProtocol.ClientType.requestKeyframe.rawValue }.count == 1)
        #expect(decoder.decoded == 0)

        // Pictures that depend on the lost one are not decoded; the keyframe recovers.
        decoder.fails = false
        stream.server([(.frame, frame(7, pts: 4000, keyframe: false)), (.frame, frame(7, pts: 5000))])
        var later: [DisplayFrame] = []
        try await until("recovery") {
            later += stream.take().filter { $0.type == DisplayProtocol.ClientType.ack.rawValue }
            return later.count == 2
        }
        #expect(later.map { $0.body["decoded_us"]?.int ?? 0 >= 0 } == [false, true])
        #expect(decoder.decoded == 1)
    }

    @Test func vsyncIsSentOncePerRefreshAndOnlyWhenTheServerPacesOnIt() async throws {
        let session = try await ready()
        session.displayWillRefresh(0, targetTimestamp: 10.0)
        session.displayWillRefresh(0, targetTimestamp: 10.0002) // another window view, same refresh
        session.displayWillRefresh(0, targetTimestamp: 10.008333)
        let ticks = stream.take().filter { $0.type == DisplayProtocol.ClientType.vsync.rawValue }
        #expect(ticks.map { $0.body["t_us"]?.int } == [10_000_000, 10_008_333])
        #expect(ticks.allSatisfy { $0.body["display"]?.int == 0 })

        let other = CabooseDisplaySessionTests()
        let unpaced = try await other.ready(features: ["ack"])
        unpaced.displayWillRefresh(0, targetTimestamp: 20)
        #expect(other.stream.take().isEmpty)
    }

    @Test func displayChangesGoOutOnTheLiveSession() async throws {
        let session = try await ready()
        session.reconfigure(ClientCapabilities(desktopWidth: 3840, desktopHeight: 2160, dpi: 192, refreshRate: 60))
        let sent = try #require(stream.take().first)
        #expect(sent.type == DisplayProtocol.ClientType.displays.rawValue)
        #expect(sent.body["displays"]?.array?.first?["width"]?.int == 3840)
        #expect(sent.body["displays"]?.array?.first?["scale"] == .double(2))
    }

    // MARK: Input

    @Test func pointerButtonsAreABitmask() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100]))])
        try await until("window") { session.windows[7] != nil }
        let window = try #require(session.windows[7])
        session.pointerButton(in: window, button: 1, pressed: true, at: CGPoint(x: 10, y: 20))
        session.pointerButton(in: window, button: 3, pressed: true, at: CGPoint(x: 10, y: 20))
        session.pointerButton(in: window, button: 1, pressed: false, at: CGPoint(x: 10, y: 20))
        session.scroll(in: window, dx: 0, dy: 42, at: CGPoint(x: 10, y: 20))
        let pointers = stream.take().filter { $0.type == DisplayProtocol.ClientType.pointer.rawValue }
        #expect(pointers.map { $0.body["buttons"]?.int } == [1, 5, 4, 4])
        #expect(pointers.last?.body["scroll"]?["dy"] == .double(42))
        #expect(pointers.last?.body["scroll"]?["precise"] == .bool(true))
    }

    @Test func keysFocusTheirWindowFirst() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100]))])
        try await until("window") { session.windows[7] != nil }
        let a = try #require(Keysyms.stroke(for: "A"))
        session.key(a, pressed: true, in: session.windows[7])
        let sent = stream.take()
        #expect(sent.map(\.type) == [DisplayProtocol.ClientType.configure.rawValue, DisplayProtocol.ClientType.key.rawValue])
        #expect(sent.first?.body["activated"] == .bool(true))
        #expect(sent.last?.body["keysym"]?.int == 0x41 && sent.last?.body["mods"]?.array == ["shift"])
    }

    @Test func fullscreenExitSendsEscapeAndRestoresGeometryWithoutMetadata() async throws {
        let session = try await ready()
        defer { session.disconnect() }
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 1000, 678]))])
        try await until("window") { session.windows[7] != nil }
        let remote = try #require(session.windows[7])
        #expect(!remote.isFullscreen)
        let target = CGRect(x: 0, y: 0, width: 466, height: 678)
        session.exitFullscreen(remote, frame: target)
        let sent = stream.take()
        let keys = sent.filter { $0.type == DisplayProtocol.ClientType.key.rawValue }
        #expect(keys.count == 2)
        #expect(keys.allSatisfy { $0.body["keysym"]?.int == 0xFF1B && $0.body["mods"]?.array == [] })
        #expect(keys.map { $0.body["pressed"] } == [.bool(true), .bool(false)])
        let configure = try #require(sent.last)
        #expect(configure.body["fullscreen"] == .bool(false))
        #expect(configure.body["maximized"] == .bool(false))
        #expect(configure.body["geometry"] == [0, 0, 466, 678])
        #expect(remote.frame == target && !remote.isFullscreen)
    }

    @Test func editsBecomeOneTextMessage() async throws {
        let session = try await ready()
        session.edit([.backspace(2), .type("the ")], in: nil)
        session.edit([.type("ab"), .backspace(1)], in: nil)
        session.edit([], in: nil)
        let texts = stream.take()
        #expect(texts.count == 2)
        #expect(texts[0].body.encoded() == ClientMessage.text(commit: "the ", deleteBefore: 2).frame.body.encoded())
        #expect(texts[1].body.encoded() == ClientMessage.text(commit: "a").frame.body.encoded())
    }

    @Test func softwareReturnSubmitsWithKeysAfterAddressText() async throws {
        let session = try await ready()
        session.edit([.type("google.ca")], in: nil)
        session.edit([.type("\n")], in: nil)
        let sent = stream.take()
        #expect(sent.map(\.type) == [DisplayProtocol.ClientType.text.rawValue,
                                   DisplayProtocol.ClientType.key.rawValue, DisplayProtocol.ClientType.key.rawValue])
        #expect(sent[0].body["commit"]?.string == "google.ca")
        #expect(sent[1].body["keysym"]?.int == 0xFF0D)
        #expect(sent[1].body["pressed"] == .bool(true))
        #expect(sent[2].body["pressed"] == .bool(false))
    }

    @Test func returnClearsUncommittedPreeditBeforeSendingTheKey() async throws {
        let session = try await ready()
        session.compose("に", selection: NSRange(location: 1, length: 0), in: nil)
        _ = stream.take()
        session.type("\n", in: nil)
        let sent = stream.take()
        #expect(sent.count == 3)
        #expect(sent[0].body["preedit"]?.string == "")
        #expect(sent[1].body["keysym"]?.int == 0xFF0D)
        #expect(sent[1].body["pressed"] == .bool(true))
        #expect(sent[2].body["pressed"] == .bool(false))
    }

    @Test func correctedTextAndPastedLinesKeepTheirOrderAroundReturn() async throws {
        let session = try await ready()
        session.edit([.backspace(2), .type("ca\nnext")], in: nil)
        session.type("\r\n", in: nil)
        let sent = stream.take()
        #expect(sent.count == 6)
        #expect(sent[0].body.encoded() == ClientMessage.text(commit: "ca", deleteBefore: 2).frame.body.encoded())
        #expect(sent[1].body["pressed"] == .bool(true))
        #expect(sent[2].body["pressed"] == .bool(false))
        #expect(sent[3].body["commit"]?.string == "next")
        #expect(sent[4].body["pressed"] == .bool(true))
        #expect(sent[5].body["pressed"] == .bool(false))
    }

    @Test func compositionIsAPreeditUntilItsCommit() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100])), (.textInput, ["id": 7, "enabled": true, "purpose": "normal"])])
        try await until("text input") { session.textInput?.enabled == true }
        let window = try #require(session.windows[7])
        session.focus(window)
        #expect(session.composesText)
        _ = stream.take()

        session.compose("にほ", selection: NSRange(location: 1, length: 0), in: window)
        // A deletion of committed text mid-composition keeps the preedit on screen.
        session.edit([.backspace(1)], in: window)
        session.edit([.type("日本")], in: window)
        session.compose("", selection: NSRange(location: 0, length: 0), in: window) // already ended by the commit
        let texts = stream.take().map { $0.body.encoded() }
        #expect(texts == [
            ClientMessage.text(commit: nil, preedit: "にほ", cursor: (3, 3)).frame.body.encoded(),
            ClientMessage.text(commit: nil, preedit: "にほ", cursor: (3, 3), deleteBefore: 1).frame.body.encoded(),
            ClientMessage.text(commit: "日本").frame.body.encoded(),
        ])

        session.compose("x", selection: NSRange(location: 1, length: 0), in: window)
        session.compose("", selection: NSRange(location: 0, length: 0), in: window) // cancelled
        #expect(stream.take().last?.body.encoded() == ClientMessage.text(commit: nil, preedit: "").frame.body.encoded())
    }

    @Test func compositionIsTypedLiveWhereTheAppHasNoTextInput() async throws {
        let session = try await ready()
        #expect(!session.composesText)
        stream.server([(.textInput, ["id": 7, "enabled": false])])
        try await until("text input") { session.textInput != nil }
        #expect(!session.composesText)
    }

    @Test func theKeyboardFollowsTextInputAndFallsBackToTheCursor() async throws {
        let session = try await ready(features: ["cursor-named"])
        #expect(session.cursorIsText == nil)
        stream.server([(.cursorNamed, ["name": "text"])])
        try await until("cursor") { session.cursorIsText == true }

        let other = CabooseDisplaySessionTests()
        let typed = try await other.ready()
        let serial = typed.cursorSerial
        other.stream.server([(.cursorNamed, ["name": "text"]), (.textInput, ["id": 7, "enabled": false])])
        try await until("text input") { typed.cursorSerial == serial + 2 }
        #expect(typed.cursorIsText == false) // the app's text-input state wins over the cursor shape
        other.stream.server([(.textInput, ["id": 7, "enabled": true, "purpose": "terminal"])])
        try await until("enabled") { typed.cursorIsText == true }
        #expect(typed.textPurpose == "terminal")
    }

    @Test func touchAndPencilFocusOnContact() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100]))])
        try await until("window") { session.windows[7] != nil }
        let window = try #require(session.windows[7])
        session.touch([TouchPoint(slot: 0, phase: .down, x: 1, y: 2), TouchPoint(slot: 1, phase: .down, x: 3, y: 4)], in: window)
        session.touch([TouchPoint(slot: 0, phase: .motion, x: 2, y: 2)], in: window)
        session.pencil(PencilSample(phase: .hover, x: 5, y: 5, pressure: 0, tilt: (0, 0), azimuth: 0), in: window)
        let sent = stream.take()
        #expect(sent.map(\.type) == [0x84, 0x90, 0x90, 0x91])
        #expect(sent[1].body["points"]?.array?.count == 2)
    }

    @Test func clipboardBothWaysWithoutEcho() async throws {
        let session = try await ready()
        var received: [String] = []
        session.onClipboardText = { received.append($0) }
        stream.server([(.clipboard, ["mime": "text/plain;charset=utf-8", "data": .bytes(Data("from linux".utf8))])])
        try await until("clipboard") { received == ["from linux"] }
        session.offerClipboard("from linux") // what the computer just sent: not echoed back
        session.offerClipboard("from the phone")
        let sent = stream.take()
        #expect(sent.count == 1)
        #expect(sent.first?.body["data"]?.data == Data("from the phone".utf8))
    }

    @Test func pongMeasuresTheRoundTrip() async throws {
        let session = try await ready()
        let sent = UInt64(CabooseDisplaySession.monotonicMicros()) - 4000
        stream.server([(.pong, ["t_us": CBOR(sent)])])
        try await until("latency") { session.latencyMs != nil }
        #expect((session.latencyMs ?? 0) >= 4)
    }

    @Test func closingTheStreamEndsTheSession() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100]))])
        try await until("window") { session.windows[7] != nil }
        stream.deliver(.closed(TransportError.closed(code: 1006)))
        try await until("closed") { if case .closed = session.state { true } else { false } }
        #expect(session.windows.isEmpty)
    }

    @Test func aStaleUpdateDoesNotSnapADraggedWindowBack() async throws {
        let session = try await ready()
        stream.server([(.windowCreate, window(7, geometry: [0, 0, 100, 100]))])
        try await until("window") { session.windows[7] != nil }
        let dragged = try #require(session.windows[7])
        session.configure(dragged, frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        #expect(dragged.surface.pixelSize == CGSize(width: 100, height: 100)) // the surface waits for the server
        stream.server([(.windowUpdate, ["id": 7, "geometry": [0, 0, 200, 200]]), (.windowCreate, window(8, geometry: [0, 0, 10, 10]))])
        try await until("handled") { session.windows[8] != nil }
        #expect(dragged.frame.size == CGSize(width: 300, height: 300))
        stream.server([(.windowUpdate, ["id": 7, "geometry": [0, 0, 300, 300]]), (.windowUpdate, ["id": 7, "geometry": [0, 0, 310, 300]])])
        try await until("confirmed") { dragged.frame.width == 310 } // after the answer, the server's word is final
        try await until("surface") { dragged.surface.pixelSize == CGSize(width: 310, height: 300) }
    }

    @Test func aClosedConnectionCannotReachTheNextOne() async throws {
        let first = MockStream(), second = MockStream()
        var streams = [first, second]
        let session = CabooseDisplaySession(stream: { streams.removeFirst() }, token: "t", displays: [display], decoders: [.hevc],
                                            makeDecoder: { _ in FakeDecoder() })
        session.connect()
        session.disconnect()
        session.connect()
        second.deliver(.opened)
        try await until("hello") { session.state == .authenticating }
        first.deliver(.closed(nil)) // the old socket's close, arriving late
        first.server([(.windowCreate, window(7, geometry: [0, 0, 10, 10]))])
        second.server([(.hello, ["version": 0, "displays": [0], "encoders": ["hevc"], "features": []])])
        try await until("ready") { session.state == .ready }
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .ready)
        #expect(session.windows.isEmpty)
    }

    // MARK: Pure helpers

    @Test func utf8Ranges() {
        #expect(CabooseDisplaySession.utf8Range(NSRange(location: 1, length: 1), in: "にほん") == (3, 6))
        #expect(CabooseDisplaySession.utf8Range(NSRange(location: 2, length: 0), in: "👍a") == (4, 4)) // 👍 is two UTF-16 units
        #expect(CabooseDisplaySession.utf8Range(NSRange(location: 9, length: 4), in: "ab") == (2, 2))
    }
}

@Suite struct DisplayInputTests {
    @Test func touchSlotsReuseTheLowestFree() {
        var slots = TouchSlots<String>()
        #expect(slots.slot(for: "a") == 0)
        #expect(slots.slot(for: "b") == 1)
        #expect(slots.slot(for: "a") == 0)
        #expect(slots.release("a") == 0)
        #expect(slots.slot(for: "c") == 0)
        #expect(slots.slot(for: "d") == 2)
        slots.removeAll()
        #expect(slots.isEmpty)
    }

    @Test func pencilTilt() {
        let upright = PencilSample.tilt(altitude: .pi / 2, azimuth: 1)
        #expect(abs(upright.x) < 1e-6 && abs(upright.y) < 1e-6)
        let east = PencilSample.tilt(altitude: .pi / 4, azimuth: 0)
        #expect(abs(east.x - 45) < 1e-9 && abs(east.y) < 1e-9)
        let south = PencilSample.tilt(altitude: .pi / 3, azimuth: .pi / 2)
        #expect(abs(south.x) < 1e-9 && abs(south.y - 30) < 1e-9)
        let flat = PencilSample.tilt(altitude: 0, azimuth: .pi)
        #expect(abs(flat.x + 90) < 1e-3)
    }

    @Test func pointerButtonBits() {
        #expect([1, 2, 3, 8, 9, 4].map(PointerButtons.bit(forXButton:)) == [1, 2, 4, 8, 16, 0])
    }

    @Test func cborRoundTripsEveryKind() throws {
        let value: CBOR = ["u": 23, "u8": 24, "u16": 300, "u32": 70000, "u64": CBOR(UInt64(1) << 40), "neg": -1, "neg16": -500,
                           "b": .bytes(Data([1, 2])), "t": "ü", "a": [true, false, .null], "f": 1.5, "m": ["k": "v"]]
        let decoded = try CBOR.decode(value.encoded())
        #expect(decoded.encoded() == value.encoded())
        #expect(decoded["u64"]?.uint64 == 1 << 40 && decoded["neg16"]?.int == -500 && decoded["f"]?.double == 1.5)
        // Shortest integer heads and float64 always.
        #expect(CBOR(24).encoded() == Data([0x18, 24]))
        #expect(CBOR(-1).encoded() == Data([0x20]))
        #expect(CBOR(1.0).encoded() == Data([0xFB, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0]))
        // Keys sort by their encoding: shorter first, then bytewise.
        #expect((["bb": 1, "a": 2, "c": 3] as CBOR).encoded() == Data([0xA3, 0x61, 0x61, 0x02, 0x61, 0x63, 0x03, 0x62, 0x62, 0x62, 0x01]))
    }

    @Test func cborDecodesLiberally() throws {
        // float16 and float32, a wide integer, a tag read through.
        #expect(try CBOR.decode(Data([0xF9, 0x3E, 0x00])) == .double(1.5))
        #expect(try CBOR.decode(Data([0xFA, 0x3F, 0xC0, 0, 0])) == .double(1.5))
        #expect(try CBOR.decode(Data([0x1B, 0, 0, 0, 0, 0, 0, 0, 5])) == .unsigned(5))
        #expect(try CBOR.decode(Data([0xC1, 0x05])) == .unsigned(5))
        #expect(CBOR.unsigned(5).double == 5) // an integer where a float is expected
        #expect(throws: CBORError.self) { try CBOR.decode(Data([0x9F, 0xFF])) } // indefinite
        #expect(throws: CBORError.self) { try CBOR.decode(Data([0x62, 0x61])) } // truncated
    }

    @Test func undecodablePayloadsAreDroppedAndTheStreamGoesOn() throws {
        var parser = DisplayFrameParser()
        let bad = Data([0x21, 1, 0, 0, 0, 0xFF])
        let good = DisplayFraming.encode(DisplayFrame(type: 0x04, body: ["id": 3]))
        let frames = try parser.append(bad + good)
        #expect(frames.count == 1 && frames.first?.body["id"]?.int == 3)
        #expect(parser.dropped == 1)
    }
}
