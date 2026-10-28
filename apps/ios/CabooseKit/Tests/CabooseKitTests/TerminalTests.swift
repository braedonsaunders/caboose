import Foundation
import Testing
@testable import CabooseKit

private let session = String(repeating: "a", count: 32)

@Suite struct TerminalProtocolTests {
    @Test func buildsTheSocketURLForANewSessionAndAReattach() {
        let base = URL(string: "https://box.example:7310")!
        #expect(TerminalProtocol.url(base: base, columns: 80, rows: 24, session: nil, offset: 9, wake: true).absoluteString
            == "wss://box.example:7310/v1/terminal?cols=80&rows=24&wake=1")
        #expect(TerminalProtocol.url(base: URL(string: "http://box:7310")!, columns: 5000, rows: 0, session: session, offset: 120, wake: false).absoluteString
            == "ws://box:7310/v1/terminal?cols=1000&rows=1&session=\(session)&offset=120")
        #expect(TerminalProtocol.url(base: base, columns: 80, rows: 24, session: "not-a-session", offset: 1, wake: false).absoluteString
            == "wss://box.example:7310/v1/terminal?cols=80&rows=24")
    }

    @Test func readsTheHostsControlMessages() {
        #expect(TerminalServerMessage(json: "{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":42,\"reset\":false}")
            == .hello(TerminalHello(session: session, offset: 42, reset: false)))
        #expect(TerminalServerMessage(json: "{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":0,\"reset\":true,\"modes\":{\"1049\":true,\"25\":false}}")
            == .hello(TerminalHello(session: session, offset: 0, reset: true, modes: [1049: true, 25: false])))
        #expect(TerminalServerMessage(json: "{\"type\":\"exit\",\"code\":3}") == .exit(code: 3, signal: nil))
        #expect(TerminalServerMessage(json: "{\"type\":\"exit\",\"code\":null,\"signal\":1}") == .exit(code: nil, signal: 1))
        for bad in ["", "[]", "{\"type\":\"hello\",\"session\":\"x\",\"offset\":0,\"reset\":true}",
                    "{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":true,\"reset\":true}",
                    "{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":1.5,\"reset\":true}",
                    "{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":1,\"reset\":1}",
                    "{\"type\":\"exit\",\"code\":null}", "{\"type\":\"notice\"}"] {
            #expect(TerminalServerMessage(json: bad) == nil, "\(bad)")
        }
    }

    @Test func aResetRestoresModesWithTheAlternateScreenFirst() {
        let hello = TerminalHello(session: session, offset: 0, reset: true, modes: [2004: true, 1049: true, 25: false, 1: true])
        #expect(String(decoding: hello.preamble, as: UTF8.self) == "\u{1b}c\u{1b}[?1049h\u{1b}[?1h\u{1b}[?25l\u{1b}[?2004h")
        #expect(TerminalHello(session: session, offset: 7, reset: false, modes: [1049: true]).preamble.isEmpty)
    }

    @Test func writesControlMessages() {
        #expect(TerminalClientMessage.resize(columns: 132, rows: 40).json == "{\"type\":\"resize\",\"cols\":132,\"rows\":40}")
        #expect(TerminalClientMessage.resize(columns: 0, rows: 9999).json == "{\"type\":\"resize\",\"cols\":1,\"rows\":500}")
        #expect(TerminalClientMessage.hangup.json == "{\"type\":\"hangup\"}")
    }

    @Test func explainsHowAConnectionEnded() {
        #expect(TerminalEnd(closeCode: 4404, reason: "session ended") == .sessionEnded)
        // URLSession may lose an application close code; the reason still decides.
        #expect(TerminalEnd(closeCode: 0, reason: "attached elsewhere") == .replaced)
        #expect(TerminalEnd(closeCode: 4408, reason: nil) == .idle)
        #expect(TerminalEnd(closeCode: 1013, reason: "too many terminal sessions") == .tooMany)
        #expect(TerminalEnd(closeCode: 1011, reason: "terminal unavailable") == .dropped("terminal unavailable"))
        #expect(TerminalEnd(closeCode: 1006, reason: "") == .dropped(nil))
        #expect(TerminalEnd(httpStatus: 401) == .unauthorized)
        #expect(TerminalEnd(httpStatus: 409) == .notRunning)
        #expect(TerminalEnd(httpStatus: 429) == .tooMany)
        #expect(TerminalEnd.dropped(nil).retries)
        #expect(!TerminalEnd.replaced.retries && !TerminalEnd.idle.retries && !TerminalEnd.exited(code: 0, signal: nil).retries)
    }

    @Test func namesSessionsByProgramAndPlace() {
        var info = TerminalSessionInfo(id: session, title: "caboose@caboose: ~", command: "vim", cwd: "/home/caboose/src/app", cols: 80, rows: 24, created: 0, attached: false)
        #expect(info.displayName == "vim — ~/src/app")
        info.cwd = "/home/caboose"
        #expect(info.displayName == "vim — ~")
        info.command = nil
        info.cwd = "/etc"
        #expect(info.displayName == "/etc")
        info.cwd = nil
        #expect(info.displayName == "caboose@caboose: ~")
        info.title = ""
        #expect(info.displayName == "Terminal")
        let decoded = try? JSONDecoder().decode(TerminalSessionInfo.self, from: Data("{\"id\":\"\(session)\",\"title\":\"\",\"command\":null,\"cwd\":null,\"cols\":80,\"rows\":24,\"created\":1,\"attached\":true}".utf8))
        #expect(decoded?.attached == true)
    }
}

@Suite struct TerminalKeysTests {
    @Test func unmodifiedCursorKeysAreLeftToTheTerminal() {
        for key in [TerminalKeys.Key.up, .down, .left, .right, .home, .end] {
            #expect(TerminalKeys.bytes(for: key, control: false, alt: false) == nil)
        }
        #expect(TerminalKeys.bytes(for: .escape, control: false, alt: false) == [0x1b])
        #expect(TerminalKeys.bytes(for: .tab, control: false, alt: false) == [0x09])
        #expect(TerminalKeys.bytes(for: .pageUp, control: false, alt: false) == Array("\u{1b}[5~".utf8))
    }

    @Test func modifiersFollowXterm() {
        #expect(TerminalKeys.bytes(for: .left, control: true, alt: false) == Array("\u{1b}[1;5D".utf8))
        #expect(TerminalKeys.bytes(for: .right, control: false, alt: true) == Array("\u{1b}[1;3C".utf8))
        #expect(TerminalKeys.bytes(for: .up, control: true, alt: true) == Array("\u{1b}[1;7A".utf8))
        #expect(TerminalKeys.bytes(for: .pageDown, control: true, alt: false) == Array("\u{1b}[6;5~".utf8))
        #expect(TerminalKeys.bytes(for: .escape, control: false, alt: true) == [0x1b, 0x1b])
        #expect(TerminalKeys.bytes(for: .tab, control: false, alt: true) == [0x1b, 0x09])
    }

    @Test func controlMakesC0Controls() {
        #expect(TerminalKeys.bytes(for: .text("c"), control: true, alt: false) == [0x03])
        #expect(TerminalKeys.bytes(for: .text("C"), control: true, alt: false) == [0x03])
        #expect(TerminalKeys.bytes(for: .text("["), control: true, alt: false) == [0x1b])
        #expect(TerminalKeys.bytes(for: .text(" "), control: true, alt: false) == [0x00])
        #expect(TerminalKeys.bytes(for: .text("?"), control: true, alt: false) == [0x7f])
        #expect(TerminalKeys.bytes(for: .text("x"), control: true, alt: true) == [0x1b, 0x18])
        #expect(TerminalKeys.bytes(for: .text("b"), control: false, alt: true) == [0x1b, 0x62])
        #expect(TerminalKeys.bytes(for: .text("é"), control: true, alt: false) == Array("é".utf8))
        #expect(TerminalKeys.bytes(for: .text("|"), control: false, alt: false) == [0x7c])
    }
}

/// A transport the test drives by hand.
private final class FakeTransport: TerminalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onEvent: (@Sendable (TerminalTransportEvent) -> Void)?
    private var _sent: [TerminalTransportMessage] = []
    private var completions: [@Sendable (Error?) -> Void] = []
    var holdsCompletions = false
    private(set) var closed = false

    var sent: [TerminalTransportMessage] { lock.withLock { _sent } }

    func open(onEvent: @escaping @Sendable (TerminalTransportEvent) -> Void) { lock.withLock { self.onEvent = onEvent } }
    func send(_ message: TerminalTransportMessage, completion: @escaping @Sendable (Error?) -> Void) {
        lock.withLock {
            _sent.append(message)
            if holdsCompletions { completions.append(completion) }
        }
        if !holdsCompletions { completion(nil) }
    }
    func close() { lock.withLock { closed = true } }
    func emit(_ event: TerminalTransportEvent) { lock.withLock { onEvent }?(event) }
    func complete() {
        let pending = lock.withLock { let all = completions; completions = []; return all }
        for completion in pending { completion(nil) }
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func record(_ event: TerminalEvent) {
        let text: String = switch event {
        case .connected(let hello): "hello \(hello.offset) \(hello.reset)"
        case .output(let data): "output \(String(decoding: data, as: UTF8.self))"
        case .ended(let end): "ended \(end)"
        }
        lock.withLock { _events.append(text) }
    }
}

@Suite struct TerminalConnectionTests {
    private func drain(_ connection: TerminalConnection) { connection.queue.sync {} }

    @Test func tracksTheOffsetAndHoldsInputUntilTheHello() {
        let transport = FakeTransport(), recorder = Recorder()
        let connection = TerminalConnection(transport: transport)
        connection.start { recorder.record($0) }
        drain(connection)
        connection.send(input: Data("ls\r".utf8))
        connection.resize(columns: 100, rows: 30)
        drain(connection)
        #expect(transport.sent.isEmpty)
        transport.emit(.message(.text("{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":10,\"reset\":false}")))
        transport.emit(.message(.data(Data("abc".utf8))))
        drain(connection)
        #expect(transport.sent == [.text("{\"type\":\"resize\",\"cols\":100,\"rows\":30}"), .data(Data("ls\r".utf8))])
        #expect(connection.offset == 13)
        #expect(connection.session == session)
        #expect(recorder.events == ["hello 10 false", "output abc"])
    }

    @Test func coalescesResizesWhileOneIsInFlight() {
        let transport = FakeTransport(), recorder = Recorder()
        transport.holdsCompletions = true
        let connection = TerminalConnection(transport: transport)
        connection.start { recorder.record($0) }
        drain(connection)
        transport.emit(.message(.text("{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":0,\"reset\":true,\"modes\":{}}")))
        for width in 81...90 { connection.resize(columns: width, rows: 24) }
        drain(connection)
        #expect(transport.sent == [.text(TerminalClientMessage.resize(columns: 81, rows: 24).json)])
        transport.complete()
        drain(connection)
        #expect(transport.sent.last == .text(TerminalClientMessage.resize(columns: 90, rows: 24).json))
        #expect(transport.sent.count == 2)
    }

    @Test func boundsInputInFlight() {
        let transport = FakeTransport(), recorder = Recorder()
        transport.holdsCompletions = true
        let connection = TerminalConnection(transport: transport)
        connection.start { recorder.record($0) }
        drain(connection)
        transport.emit(.message(.text("{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":0,\"reset\":true,\"modes\":{}}")))
        let chunk = Data(count: 100 * 1024)
        for _ in 0..<5 { connection.send(input: chunk) }
        drain(connection)
        #expect(transport.sent.count == 3)
        transport.complete()
        drain(connection)
        #expect(transport.sent.count == 5)
    }

    @Test func reportsAnExitThenTheClose() {
        let transport = FakeTransport(), recorder = Recorder()
        let connection = TerminalConnection(transport: transport)
        connection.start { recorder.record($0) }
        drain(connection)
        transport.emit(.message(.text("{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":0,\"reset\":true,\"modes\":{}}")))
        transport.emit(.message(.text("{\"type\":\"exit\",\"code\":7}")))
        transport.emit(.closed(code: 1000, reason: "exited"))
        transport.emit(.message(.data(Data("late".utf8))))
        drain(connection)
        #expect(recorder.events == ["hello 0 true", "ended exited(code: Optional(7), signal: nil)"])
    }

    @Test func rejectsAnythingOutsideTheContract() {
        let transport = FakeTransport(), recorder = Recorder()
        let connection = TerminalConnection(transport: transport)
        connection.start { recorder.record($0) }
        drain(connection)
        transport.emit(.message(.data(Data("before hello".utf8))))
        drain(connection)
        #expect(transport.closed)
        #expect(recorder.events == ["ended dropped(Optional(\"The computer sent output before its hello.\"))"])
    }

    @Test func mapsRefusalsAndCloses() {
        for (event, expected) in [(TerminalTransportEvent.refused(status: 409), "ended notRunning"),
                                  (.closed(code: 4404, reason: "session ended"), "ended sessionEnded"),
                                  (.failed("offline"), "ended dropped(Optional(\"offline\"))")] {
            let transport = FakeTransport(), recorder = Recorder()
            let connection = TerminalConnection(transport: transport)
            connection.start { recorder.record($0) }
        drain(connection)
            drain(connection)
            transport.emit(event)
            drain(connection)
            #expect(recorder.events == [expected])
        }
    }

    @Test func closingKeepsQuiet() {
        let transport = FakeTransport(), recorder = Recorder()
        let connection = TerminalConnection(transport: transport)
        connection.start { recorder.record($0) }
        drain(connection)
        transport.emit(.message(.text("{\"type\":\"hello\",\"session\":\"\(session)\",\"offset\":0,\"reset\":true,\"modes\":{}}")))
        connection.close()
        transport.emit(.closed(code: 1000, reason: nil))
        drain(connection)
        #expect(transport.closed)
        #expect(recorder.events == ["hello 0 true"])
    }
}
