import Foundation
import Network
import Testing
@testable import CabooseKit

struct HTTP1WebSocketTests {
    @Test func offersOnlyHTTP1() {
        #expect(HTTP1Upgrade.applicationProtocols == ["http/1.1"])
        #expect(HTTP1Upgrade.isSecure(URL(string: "wss://box.example/v1/control")!))
        #expect(HTTP1Upgrade.isSecure(URL(string: "https://box.example")!))
        #expect(!HTTP1Upgrade.isSecure(URL(string: "ws://10.0.0.2:7310/v1/control")!))
    }

    @Test func answersTheRFCExampleKey() {
        #expect(WebSocketHandshake.accept(for: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        #expect(Data(base64Encoded: WebSocketHandshake.makeKey())?.count == 16)
    }

    @Test func writesAnHTTP1UpgradeRequest() throws {
        let url = URL(string: "wss://lucid.example.ts.net:8443/v1/computers/c-1/terminal?cols=80&rows=24")!
        let request = try WebSocketHandshake.request(url: url, key: "k", subprotocols: ["caboose.gpu.live.v1"],
                                                     headers: [("Authorization", "Bearer t")])
        let text = String(decoding: request, as: UTF8.self)
        #expect(text == "GET /v1/computers/c-1/terminal?cols=80&rows=24 HTTP/1.1\r\nHost: lucid.example.ts.net:8443\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: k\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: caboose.gpu.live.v1\r\nAuthorization: Bearer t\r\n\r\n")
        let plain = String(decoding: try WebSocketHandshake.request(url: URL(string: "wss://box.example:443")!, key: "k"), as: UTF8.self)
        #expect(plain.hasPrefix("GET / HTTP/1.1\r\nHost: box.example\r\n"))
        let v6 = String(decoding: try WebSocketHandshake.request(url: URL(string: "ws://[fd7a:115c:a1e0::1]:7310/v1/ai")!, key: "k"), as: UTF8.self)
        #expect(v6.contains("Host: [fd7a:115c:a1e0::1]:7310\r\n"))
        #expect(throws: WebSocketHandshake.Failure.invalidAddress) {
            try WebSocketHandshake.request(url: URL(string: "ftp://box.example")!, key: "k")
        }
        #expect(throws: WebSocketHandshake.Failure.invalidAddress) {
            try WebSocketHandshake.request(url: URL(string: "wss://box.example")!, key: "k", headers: [("X", "a\r\nInjected: 1")])
        }
    }

    @Test func readsAndChecksTheAnswer() throws {
        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: binary\r\nX-Caboose-GPU-Resume: abc\r\n\r\n"
        #expect(try WebSocketHandshake.parseResponse(Data(head.dropLast(3).utf8)) == nil)
        let parsed = try #require(try WebSocketHandshake.parseResponse(Data((head + "\u{81}").utf8)))
        #expect(parsed.consumed == head.utf8.count)
        #expect(parsed.response.status == 101)
        #expect(parsed.response.value("x-caboose-gpu-resume") == "abc")
        #expect(parsed.response.subprotocol == "binary")
        try WebSocketHandshake.validate(parsed.response, key: key, subprotocols: ["binary"])
        #expect(throws: WebSocketHandshake.Failure.unexpectedSubprotocol("binary")) {
            try WebSocketHandshake.validate(parsed.response, key: key, subprotocols: ["other"])
        }
        #expect(throws: WebSocketHandshake.Failure.badAccept) {
            try WebSocketHandshake.validate(parsed.response, key: "another", subprotocols: ["binary"])
        }
        let gone = try #require(try WebSocketHandshake.parseResponse(Data("HTTP/1.1 410 Gone\r\nContent-Length: 0\r\n\r\n".utf8)))
        #expect(throws: WebSocketHandshake.Failure.refused(status: 410)) {
            try WebSocketHandshake.validate(gone.response, key: key, subprotocols: [])
        }
        #expect(throws: WebSocketHandshake.Failure.malformedResponse) {
            try WebSocketHandshake.parseResponse(Data("HTTP/2 200\r\n\r\n".utf8))
        }
        #expect(throws: WebSocketHandshake.Failure.responseTooLarge) {
            try WebSocketHandshake.parseResponse(Data(repeating: 0x41, count: WebSocketHandshake.maximumResponseHead + 1))
        }
    }

    @Test func framesWithEveryLengthFormAndMasks() {
        let mask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
        for size in [0, 5, 125, 126, 1000, 65_535, 65_536, 200_003] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 7) })
            let frame = WebSocketFrame.encode(.binary, payload: payload, mask: mask)
            #expect(frame[0] == 0x82)
            #expect(frame[1] & 0x80 == 0x80)
            let header = size < 126 ? 2 : size < 65_536 ? 4 : 10
            #expect(frame.count == header + 4 + size)
            #expect(Array(frame[header..<(header + 4)]) == mask)
            let unmasked = Data(frame[(header + 4)...].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            #expect(unmasked == payload, "size \(size)")
        }
        #expect(WebSocketFrame.closePayload(code: 4001, reason: "suspended") == Data([0x0f, 0xa1]) + Data("suspended".utf8))
    }

    @Test func joinsFragmentsAroundControlFrames() throws {
        var reader = WebSocketReader(maximumMessageSize: 1024)
        // "Hel" (text, not final), a ping, "lo" (continuation, final), a binary message, a close.
        let bytes: [UInt8] = [0x01, 3] + Array("Hel".utf8) + [0x89, 1, 0x2a] + [0x80, 2] + Array("lo".utf8)
            + [0x82, 126, 0x00, 0x03, 1, 2, 3] + [0x88, 4, 0x0f, 0xa1, 0x6f, 0x6b]
        // Arriving a byte at a time changes nothing.
        var events: [WebSocketReader.Event] = []
        for byte in bytes {
            reader.append(Data([byte]))
            while let event = try reader.next() { events.append(event) }
        }
        #expect(events == [.ping(Data([0x2a])), .text("Hello"), .binary(Data([1, 2, 3])), .close(code: 4001, reason: "ok")])
        #expect(reader.buffered == 0)
    }

    @Test func refusesWhatBreaksTheProtocol() {
        func failure(_ bytes: [UInt8], limit: Int = 1024) -> WebSocketReader.Failure? {
            var reader = WebSocketReader(maximumMessageSize: limit)
            reader.append(Data(bytes))
            do { _ = try reader.next(); return nil } catch { return error as? WebSocketReader.Failure }
        }
        #expect(failure([0x82, 0x81, 0, 0, 0, 0, 1])?.closeCode == 1002) // masked by the server
        #expect(failure([0xc2, 0])?.closeCode == 1002) // reserved bit
        #expect(failure([0x83, 0])?.closeCode == 1002) // unknown opcode
        #expect(failure([0x80, 0])?.closeCode == 1002) // continuation of nothing
        #expect(failure([0x09, 0])?.closeCode == 1002) // fragmented ping
        #expect(failure([0x82, 126, 0x04, 0x01], limit: 1024)?.closeCode == 1009)
        #expect(failure([0x81, 2, 0xff, 0xfe])?.closeCode == 1007)
        #expect(failure([0x88, 1, 0x03])?.closeCode == 1002)
        #expect(failure([0x82, 5, 1]) == nil) // incomplete, not wrong
    }

    /// The whole client against a minimal HTTP/1.1 WebSocket server on loopback.
    @Test func talksToAServer() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let port = try await server.ready()
        let socket = HTTP1WebSocket(url: URL(string: "ws://127.0.0.1:\(port)/echo?x=1")!, subprotocols: ["binary"],
                                    headers: [("Authorization", "Bearer token")], timeout: 5)
        let events = AsyncStream<HTTP1WebSocket.Event> { continuation in
            socket.open { event in
                continuation.yield(event)
                if case .closed = event { continuation.finish() }
            }
        }
        var iterator = events.makeAsyncIterator()
        guard case .opened(let response) = await iterator.next() else { Issue.record("not opened"); return }
        #expect(response.value("X-Caboose-Test") == "hello")
        #expect(response.subprotocol == "binary")
        #expect(server.lastRequest.contains("GET /echo?x=1 HTTP/1.1\r\n"))
        #expect(server.lastRequest.contains("Authorization: Bearer token\r\n"))
        guard case .message(.string("hi")) = await iterator.next() else { Issue.record("no greeting"); return }
        let big = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
        socket.send(.data(big))
        guard case .message(.data(let echoed)) = await iterator.next() else { Issue.record("no echo"); return }
        #expect(echoed == big)
        let ponged = await withCheckedContinuation { continuation in socket.ping { continuation.resume(returning: $0 == nil) } }
        #expect(ponged)
        socket.send(.string("close"))
        guard case .closed(let close) = await iterator.next() else { Issue.record("not closed"); return }
        #expect(close.code == 4001 && close.reason == "bye" && close.failure == nil)

        let refused = HTTP1WebSocket(url: URL(string: "ws://127.0.0.1:\(port)/gone")!, timeout: 5)
        let ended = await withCheckedContinuation { continuation in
            refused.open { event in if case .closed(let close) = event { continuation.resume(returning: close) } }
        }
        #expect(ended.refusedStatus == 410)
    }

    /// The GPU session pauses while it takes a message; the socket must not hand it another,
    /// however many it has already read.
    @Test func aPauseInsideTheHandlerStopsTheNextMessage() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let port = try await server.ready()
        let socket = HTTP1WebSocket(url: URL(string: "ws://127.0.0.1:\(port)/echo")!, subprotocols: ["binary"], timeout: 5)
        let lock = NSLock()
        nonisolated(unsafe) var frames = 0
        nonisolated(unsafe) var opened = false
        socket.open { event in
            switch event {
            case .opened: lock.withLock { opened = true }
            case .message(.data):
                let first = lock.withLock { () -> Bool in frames += 1; return frames == 1 }
                if first { socket.setReceivingPaused(true) }
            default: break
            }
        }
        for _ in 0..<200 where !lock.withLock({ opened }) { try await Task.sleep(for: .milliseconds(50)) }
        // 500 one-byte frames in one write: they arrive together, in one read.
        socket.send(.string("burst"))
        for _ in 0..<200 where lock.withLock({ frames }) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(lock.withLock { frames } == 1)
        socket.setReceivingPaused(false)
        for _ in 0..<200 where lock.withLock({ frames }) < LoopbackWebSocketServer.burst { try await Task.sleep(for: .milliseconds(50)) }
        #expect(lock.withLock { frames } == LoopbackWebSocketServer.burst)
        socket.close()
    }

    @Test func readsManyFramesFromOneAppendInOrder() throws {
        var reader = WebSocketReader(maximumMessageSize: 1024)
        var bytes = Data()
        for index in 0..<20_000 { bytes.append(contentsOf: [0x82, 2, UInt8(index >> 8 & 0xff), UInt8(index & 0xff)]) }
        // A partial frame left over is kept for the next append.
        reader.append(bytes + Data([0x82, 2, 0xaa]))
        var count = 0
        while let event = try reader.next() {
            #expect(event == .binary(Data([UInt8(count >> 8 & 0xff), UInt8(count & 0xff)])))
            count += 1
        }
        #expect(count == 20_000)
        #expect(reader.buffered == 3)
        reader.append(Data([0xbb]))
        #expect(try reader.next() == .binary(Data([0xaa, 0xbb])))
        #expect(reader.buffered == 0)
    }

    @Test func closeFramesCarryOnlyCodesThatMayBeSent() {
        let reason = String(repeating: "a", count: 122) + "é"
        let payload = WebSocketFrame.closePayload(code: 1000, reason: reason)
        #expect(payload.count == 2 + 122)
        #expect(String(data: payload.dropFirst(2), encoding: .utf8) != nil)
        #expect(WebSocketFrame.closePayload(code: 4001).prefix(2) == Data([0x0f, 0xa1]))
        for code in [0, 999, 1004, 1005, 1006, 1015, 2000, 5000] {
            #expect(WebSocketFrame.sendableCode(code) == 1002, "\(code)")
            #expect(WebSocketFrame.sendableCode(code, echo: true) == 1000, "\(code)")
        }
        for code in [1000, 1001, 1002, 1008, 1011, 3000, 4001, 4410] { #expect(WebSocketFrame.sendableCode(code) == code) }
        #expect(WebSocketFrame.closePayload(code: 1005).prefix(2) == Data([0x03, 0xea]))
    }

    @Test func encodesAnIPv6ZoneInTheHostHeader() throws {
        #expect(WebSocketHandshake.zoneEncoded("fe80::1%en0") == "fe80::1%25en0")
        #expect(WebSocketHandshake.zoneEncoded("fe80::1%25en0") == "fe80::1%25en0")
        #expect(WebSocketHandshake.zoneEncoded("fd7a:115c:a1e0::1") == "fd7a:115c:a1e0::1")
        if let url = URL(string: "ws://[fe80::1%25en0]:7310/v1/ai") {
            let text = String(decoding: try WebSocketHandshake.request(url: url, key: "k"), as: UTF8.self)
            #expect(text.contains("Host: [fe80::1%25en0]:7310\r\n"))
        }
    }

    @Test func holdsBackMessagesWhilePaused() async throws {
        let server = try LoopbackWebSocketServer()
        defer { server.stop() }
        let port = try await server.ready()
        let socket = HTTP1WebSocket(url: URL(string: "ws://127.0.0.1:\(port)/echo")!, subprotocols: ["binary"], timeout: 5)
        let lock = NSLock()
        nonisolated(unsafe) var messages: [HTTP1WebSocket.Message] = []
        nonisolated(unsafe) var opened = false
        // Paused before opening: the upgrade is still read, messages are not.
        socket.setReceivingPaused(true)
        socket.open { event in
            lock.withLock {
                if case .opened = event { opened = true }
                if case .message(let message) = event { messages.append(message) }
            }
        }
        func count() -> Int { lock.withLock { messages.count } }
        for _ in 0..<200 where !lock.withLock({ opened }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(lock.withLock { opened })
        try await Task.sleep(for: .milliseconds(300))
        #expect(count() == 0)
        socket.send(.data(Data([1, 2, 3])))
        try await Task.sleep(for: .milliseconds(300))
        #expect(count() == 0)
        socket.setReceivingPaused(false)
        for _ in 0..<200 where count() < 2 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(lock.withLock { messages } == [.string("hi"), .data(Data([1, 2, 3]))])
        // Closing sends its code before the connection goes, as a suspended GPU socket's 4001 must.
        socket.close(code: 4001)
        for _ in 0..<200 where server.closeCode == nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(server.closeCode == 4001)
    }
}

/// Just enough of a WebSocket server for `talksToAServer`: answers `/gone` with 410, greets with
/// "hi", echoes binary, answers pings, and on the text "close" closes with 4001 "bye".
private final class LoopbackWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "caboose.test.ws-server")
    private let lock = NSLock()
    private var request = ""
    private var receivedClose: Int?
    var lastRequest: String { lock.withLock { request } }
    /// The code of the last close frame a client sent.
    var closeCode: Int? { lock.withLock { receivedClose } }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    func ready() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let once = NSLock()
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                once.lock(); defer { once.unlock() }
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func readHead() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, error in
                guard error == nil, let data else { return }
                buffer.append(data)
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return readHead() }
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                lock.withLock { request = head + "\r\n" }
                if head.hasPrefix("GET /gone") {
                    connection.send(content: Data("HTTP/1.1 410 Gone\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let key = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
                    .split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) ?? ""
                let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketHandshake.accept(for: key))\r\nSec-WebSocket-Protocol: binary\r\nX-Caboose-Test: hello\r\n\r\n"
                connection.send(content: Data(reply.utf8) + Self.frame(0x1, Data("hi".utf8)), completion: .contentProcessed { _ in })
                readFrames()
            }
        }
        func readFrames() {
            while let (opcode, payload, used) = Self.clientFrame(buffer) {
                buffer.removeFirst(used)
                switch opcode {
                case 0x2: connection.send(content: Self.frame(0x2, payload), completion: .contentProcessed { _ in })
                case 0x9: connection.send(content: Self.frame(0xA, payload), completion: .contentProcessed { _ in })
                case 0x1 where payload == Data("burst".utf8):
                    var frames = Data()
                    for index in 0..<Self.burst { frames.append(Self.frame(0x2, Data([UInt8(index & 0xff)]))) }
                    connection.send(content: frames, completion: .contentProcessed { _ in })
                case 0x1 where payload == Data("close".utf8):
                    connection.send(content: Self.frame(0x8, Data([0x0f, 0xa1]) + Data("bye".utf8)), completion: .contentProcessed { _ in })
                case 0x8:
                    if payload.count >= 2 { lock.withLock { receivedClose = Int(payload[0]) << 8 | Int(payload[1]) } }
                    connection.cancel(); return
                default: break
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                guard error == nil, !complete || data != nil else { connection.cancel(); return }
                if let data { buffer.append(data) }
                readFrames()
            }
        }
        readHead()
    }

    /// How many frames the text "burst" is answered with, all in one write.
    static let burst = 500

    static func frame(_ opcode: UInt8, _ payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count < 65_536 { frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)]) }
        else { frame.append(127); for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xff)) } }
        return frame + payload
    }

    /// A masked client frame at the start of `buffer`: its opcode, unmasked payload and size.
    static func clientFrame(_ buffer: Data) -> (UInt8, Data, Int)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7f), header = 2
        if length == 126 { guard bytes.count >= 4 else { return nil }; length = Int(bytes[2]) << 8 | Int(bytes[3]); header = 4 }
        else if length == 127 { guard bytes.count >= 10 else { return nil }; length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }; header = 10 }
        guard bytes.count >= header + 4, buffer.count >= header + 4 + length else { return nil }
        let mask = Array(bytes[header..<(header + 4)])
        let start = buffer.startIndex + header + 4
        let payload = Data(buffer[start..<(start + length)].enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return (bytes[0] & 0x0f, payload, header + 4 + length)
    }
}
