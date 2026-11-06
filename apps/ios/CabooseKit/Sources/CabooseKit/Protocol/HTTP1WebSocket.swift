import CryptoKit
import Foundation
import Network

/// How every WebSocket the app opens reaches its host: an RFC 6455 upgrade over HTTP/1.1.
///
/// A WebSocket upgrade exists only in HTTP/1.1. A TLS server that also speaks HTTP/2 (Tailscale
/// Serve, most reverse proxies) picks HTTP/2 when the client offers it, and the upgrade then
/// cannot happen, so a socket offers `http/1.1` alone. URLSession has no way to say so for its
/// WebSocket tasks; Network.framework does, through TLS's application protocols.
public enum HTTP1Upgrade {
    /// The only application protocol a WebSocket's TLS offers.
    public static let applicationProtocols = ["http/1.1"]

    /// TLS for a WebSocket: certificate checks as for any connection, offering only HTTP/1.1.
    public static func tlsOptions() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        for name in applicationProtocols {
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, name)
        }
        return tls
    }

    /// Whether a socket address is reached over TLS (`wss`, or `https` before conversion).
    public static func isSecure(_ url: URL) -> Bool {
        ["wss", "https"].contains(url.scheme?.lowercased() ?? "")
    }
}

/// The client's half of the opening handshake (RFC 6455 §4.1): the request it sends and the
/// checks on the answer.
public enum WebSocketHandshake {
    public enum Failure: Error, Equatable, LocalizedError {
        case invalidAddress
        case malformedResponse
        case responseTooLarge
        /// The server answered, but did not switch protocols: its HTTP status.
        case refused(status: Int)
        case badAccept
        case unexpectedSubprotocol(String?)
        /// The server named extensions though none were offered.
        case unexpectedExtensions(String)

        public var errorDescription: String? {
            switch self {
            case .invalidAddress: "The connection's address is not a WebSocket address."
            case .malformedResponse: "The host's answer to the connection was not HTTP."
            case .responseTooLarge: "The host's answer to the connection was too long."
            case .refused(let status): "The host refused the connection (HTTP \(status))."
            case .badAccept: "The host's answer to the connection did not match the request."
            case .unexpectedSubprotocol(let name): "The host chose an unexpected protocol (\(name ?? "none"))."
            case .unexpectedExtensions(let names): "The host chose extensions that were not offered (\(names))."
            }
        }
    }

    /// The HTTP answer to the upgrade: its status and headers, names lowercased.
    public struct Response: Equatable, Sendable {
        public let status: Int
        public let headers: [String: String]

        public init(status: Int, headers: [String: String]) {
            self.status = status
            self.headers = headers
        }

        public func value(_ name: String) -> String? { headers[name.lowercased()] }
        public var subprotocol: String? { value("Sec-WebSocket-Protocol") }
    }

    /// The longest answer head accepted.
    public static let maximumResponseHead = 16 * 1024

    /// A fresh 16-byte nonce, base64.
    public static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }

    /// The `Sec-WebSocket-Accept` a server must answer `key` with.
    public static func accept(for key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }

    /// The upgrade request for `url`. `headers` are sent as given after the protocol's own;
    /// `subprotocols` become `Sec-WebSocket-Protocol`.
    public static func request(url: URL, key: String, subprotocols: [String] = [],
                               headers: [(name: String, value: String)] = []) throws -> Data {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["ws", "wss", "http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else {
            throw Failure.invalidAddress
        }
        let secure = scheme == "wss" || scheme == "https"
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let bracketed = bare.contains(":") ? "[\(zoneEncoded(bare))]" : bare
        let authority = components.port.map { port in
            (secure && port == 443) || (!secure && port == 80) ? bracketed : "\(bracketed):\(port)"
        } ?? bracketed
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        var lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(authority)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
        ]
        if !subprotocols.isEmpty { lines.append("Sec-WebSocket-Protocol: \(subprotocols.joined(separator: ", "))") }
        for header in headers {
            guard !header.name.isEmpty, !(header.name + header.value).unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                throw Failure.invalidAddress
            }
            lines.append("\(header.name): \(header.value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// An IPv6 literal with its zone id's `%` written as `%25` (RFC 6874), as a Host header needs.
    static func zoneEncoded(_ host: String) -> String {
        guard let percent = host.firstIndex(of: "%") else { return host }
        let zone = host[host.index(after: percent)...]
        if zone.hasPrefix("25") { return host }
        return host[..<percent] + "%25" + zone
    }

    /// The answer's head once `buffer` holds all of it, with the bytes it took; nil while more
    /// must arrive.
    public static func parseResponse(_ buffer: Data) throws -> (response: Response, consumed: Int)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            if buffer.count > maximumResponseHead { throw Failure.responseTooLarge }
            return nil
        }
        let consumed = end.upperBound - buffer.startIndex
        guard consumed <= maximumResponseHead,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            throw consumed > maximumResponseHead ? Failure.responseTooLarge : Failure.malformedResponse
        }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else {
            throw Failure.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw Failure.malformedResponse }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        return (Response(status: status, headers: headers), consumed)
    }

    /// Checks an answer completes the upgrade `key` asked for, offering `subprotocols`.
    public static func validate(_ response: Response, key: String, subprotocols: [String]) throws {
        guard response.status == 101 else { throw Failure.refused(status: response.status) }
        guard response.value("Upgrade")?.lowercased() == "websocket",
              response.value("Connection")?.lowercased().split(separator: ",").contains(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "upgrade"
              }) == true else { throw Failure.malformedResponse }
        guard response.value("Sec-WebSocket-Accept") == accept(for: key) else { throw Failure.badAccept }
        if let chosen = response.subprotocol, !subprotocols.contains(chosen) { throw Failure.unexpectedSubprotocol(chosen) }
        // This client offers no extensions, so the server may name none.
        if let extensions = response.value("Sec-WebSocket-Extensions"), !extensions.trimmingCharacters(in: .whitespaces).isEmpty {
            throw Failure.unexpectedExtensions(extensions)
        }
    }
}

/// WebSocket framing (RFC 6455 §5): frames a client sends, always masked, and the frames it
/// receives, never masked, joined into messages.
public enum WebSocketFrame {
    public enum Opcode: UInt8, Sendable {
        case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10
        var isControl: Bool { rawValue >= 8 }
    }

    /// One complete frame from the client, its payload masked with `mask`.
    public static func encode(_ opcode: Opcode, payload: Data, mask: [UInt8]) -> Data {
        precondition(mask.count == 4)
        var frame = Data(capacity: payload.count + 14)
        frame.append(0x80 | opcode.rawValue)
        switch payload.count {
        case ..<126:
            frame.append(0x80 | UInt8(payload.count))
        case ..<65_536:
            frame.append(0x80 | 126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xff))
        default:
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xff)) }
        }
        frame.append(contentsOf: mask)
        let start = frame.count
        frame.append(payload)
        frame.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            applyMask(mask, to: UnsafeMutableBufferPointer(rebasing: bytes[start...]))
        }
        return frame
    }

    /// A close frame's payload: the code, and a reason cut to fit a control frame.
    public static func closePayload(code: Int, reason: String? = nil) -> Data {
        let code = sendableCode(code)
        var payload = Data([UInt8((code >> 8) & 0xff), UInt8(code & 0xff)])
        if let reason {
            // At most 123 bytes, never ending inside a character.
            var kept = 0
            for scalar in reason.unicodeScalars {
                let size = String(scalar).utf8.count
                if kept + size > 123 { break }
                kept += size
            }
            payload.append(Data(reason.utf8).prefix(kept))
        }
        return payload
    }

    /// A close code a frame may carry (RFC 6455 §7.4): 1005, 1006 and 1015 are only ever
    /// reported, never sent, and nothing below 1000 or past 4999 is defined; those become
    /// 1002 (protocol error), and an echo of a peer's such code becomes 1000.
    public static func sendableCode(_ code: Int, echo: Bool = false) -> Int {
        let forbidden = code < 1000 || code > 4999 || [1004, 1005, 1006, 1015].contains(code) || (1016...2999).contains(code)
        return forbidden ? (echo ? 1000 : 1002) : code
    }

    /// XORs `bytes` with the repeating 4-byte `mask`, a word at a time.
    static func applyMask(_ mask: [UInt8], to bytes: UnsafeMutableBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        let count = bytes.count
        var index = 0
        let word = UInt64(mask[0]) | UInt64(mask[1]) << 8 | UInt64(mask[2]) << 16 | UInt64(mask[3]) << 24
        let wide = word | word << 32
        while index + 8 <= count {
            let pointer = UnsafeMutableRawPointer(base + index)
            pointer.storeBytes(of: pointer.loadUnaligned(as: UInt64.self) ^ wide, as: UInt64.self)
            index += 8
        }
        while index < count {
            base[index] ^= mask[index & 3]
            index += 1
        }
    }

    public static func randomMask() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }
}

/// Turns the bytes a server sends into messages and control frames.
public struct WebSocketReader: Sendable {
    public enum Event: Equatable, Sendable {
        case text(String)
        case binary(Data)
        case ping(Data)
        case pong(Data)
        /// The server's close frame: its code (nil when it gave none) and reason.
        case close(code: Int?, reason: String?)
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// The bytes break the protocol; the connection closes with 1002.
        case protocolError(String)
        /// A message longer than allowed; the connection closes with 1009.
        case tooLarge
        /// A text message that is not UTF-8; the connection closes with 1007.
        case invalidText

        public var closeCode: Int {
            switch self {
            case .protocolError: 1002
            case .tooLarge: 1009
            case .invalidText: 1007
            }
        }

        public var errorDescription: String? {
            switch self {
            case .protocolError(let detail): "The connection broke the WebSocket protocol: \(detail)."
            case .tooLarge: "A message on the connection was too large."
            case .invalidText: "A text message on the connection was not UTF-8."
            }
        }
    }

    public let maximumMessageSize: Int
    /// Bytes received; frames before `offset` are already read.
    private var buffer = Data()
    private var offset = 0
    private var fragments: Data?
    private var fragmentOpcode: WebSocketFrame.Opcode?

    public init(maximumMessageSize: Int) {
        self.maximumMessageSize = maximumMessageSize
    }

    /// Bytes held for frames not yet complete.
    public var buffered: Int { buffer.count - offset }

    public mutating func append(_ data: Data) {
        // Drop what was read once per append, never per frame.
        if offset > 0 {
            if offset == buffer.count { buffer.removeAll(keepingCapacity: true) }
            else { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset)) }
            offset = 0
        }
        buffer.append(data)
    }

    /// The next whole message or control frame, or nil until more bytes arrive.
    public mutating func next() throws -> Event? {
        while true {
            guard let (fin, opcode, payload) = try nextFrame() else { return nil }
            if opcode.isControl {
                switch opcode {
                case .ping: return .ping(payload)
                case .pong: return .pong(payload)
                default:
                    guard payload.count != 1 else { throw Failure.protocolError("a close frame of one byte") }
                    let code = payload.count >= 2 ? Int(payload[payload.startIndex]) << 8 | Int(payload[payload.startIndex + 1]) : nil
                    if let code, WebSocketFrame.sendableCode(code) != code { throw Failure.protocolError("a close code that may not be sent (\(code))") }
                    var reason: String?
                    if payload.count > 2 {
                        guard let text = String(data: payload.dropFirst(2), encoding: .utf8) else { throw Failure.invalidText }
                        reason = text
                    }
                    return .close(code: code, reason: reason)
                }
            }
            if opcode == .continuation {
                guard var gathered = fragments, let first = fragmentOpcode else { throw Failure.protocolError("a continuation with no message") }
                guard gathered.count + payload.count <= maximumMessageSize else { throw Failure.tooLarge }
                // Let go of the stored copy first, so appending does not copy the whole message.
                fragments = nil
                gathered.append(payload)
                if !fin { fragments = gathered; continue }
                fragments = nil
                fragmentOpcode = nil
                return try message(first, gathered)
            }
            guard fragments == nil else { throw Failure.protocolError("a new message inside a fragmented one") }
            if !fin {
                fragments = payload
                fragmentOpcode = opcode
                continue
            }
            return try message(opcode, payload)
        }
    }

    private func message(_ opcode: WebSocketFrame.Opcode, _ payload: Data) throws -> Event {
        if opcode == .text {
            guard let text = String(data: payload, encoding: .utf8) else { throw Failure.invalidText }
            return .text(text)
        }
        return .binary(payload)
    }

    private mutating func nextFrame() throws -> (Bool, WebSocketFrame.Opcode, Data)? {
        let count = buffer.count - offset
        guard count >= 2 else { return nil }
        let start = buffer.startIndex + offset
        let first = buffer[start], second = buffer[start + 1]
        guard first & 0x70 == 0 else { throw Failure.protocolError("reserved bits set") }
        guard let opcode = WebSocketFrame.Opcode(rawValue: first & 0x0f) else { throw Failure.protocolError("an unknown opcode") }
        guard second & 0x80 == 0 else { throw Failure.protocolError("a masked frame from the server") }
        let fin = first & 0x80 != 0
        var header = 2
        var length = UInt64(second & 0x7f)
        if length == 126 {
            guard count >= 4 else { return nil }
            length = UInt64(buffer[start + 2]) << 8 | UInt64(buffer[start + 3])
            header = 4
        } else if length == 127 {
            guard count >= 10 else { return nil }
            length = 0
            for index in 0..<8 { length = length << 8 | UInt64(buffer[start + 2 + index]) }
            header = 10
        }
        if opcode.isControl {
            guard fin, length <= 125 else { throw Failure.protocolError("a fragmented or long control frame") }
        } else if length > UInt64(maximumMessageSize) {
            throw Failure.tooLarge
        }
        let total = header + Int(length)
        guard count >= total else { return nil }
        let payload = Data(buffer[(start + header)..<(start + total)])
        offset += total
        return (fin, opcode, payload)
    }
}

/// A WebSocket client over Network.framework that always upgrades over HTTP/1.1
/// (`HTTP1Upgrade`): the host's control, terminal, GPU and AI sockets. The display's own
/// stream (`WebSocketStream`) uses Network.framework's WebSocket protocol on the same TLS.
///
/// Events arrive in order on the socket's queue. Receiving can be held back
/// (`setReceivingPaused`), so a consumer that cannot keep up stops reading from the network
/// and TCP pushes back on the host.
public final class HTTP1WebSocket: @unchecked Sendable {
    public enum Message: Equatable, Sendable {
        case data(Data)
        case string(String)
    }

    /// How the socket ended.
    public struct Close: Error, Sendable, LocalizedError {
        /// The server's close code; nil when it closed without one or never opened.
        public var code: Int?
        public var reason: String?
        /// The HTTP status when the server answered the upgrade without switching protocols.
        public var refusedStatus: Int?
        /// What went wrong, when the socket failed rather than closed.
        public var failure: String?

        public var errorDescription: String? {
            if let failure { return failure }
            if let refusedStatus { return "The host refused the connection (HTTP \(refusedStatus))." }
            return "The connection closed (code \(code ?? 1005))."
        }
    }

    public enum Event: Sendable {
        /// The upgrade completed; the answer carries the host's headers.
        case opened(WebSocketHandshake.Response)
        case message(Message)
        case closed(Close)
    }

    private let url: URL
    private let subprotocols: [String]
    private let headers: [(name: String, value: String)]
    private let timeout: TimeInterval
    private let key = WebSocketHandshake.makeKey()
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var handler: (@Sendable (Event) -> Void)?
    private var reader: WebSocketReader
    private var head = Data()
    private var opened = false
    private var ended = false
    /// Receiving held back (`setReceivingPaused`); set from any thread, read before each message.
    private let pauseLock = NSLock()
    private var pausedFlag = false
    private var paused: Bool { pauseLock.withLock { pausedFlag } }
    private var reading = false
    /// Pings awaiting their pong, by payload, oldest first.
    private var pongs: [(payload: Data, answer: @Sendable (Error?) -> Void)] = []
    private var pingCount: UInt32 = 0

    /// `timeout` bounds connecting and the upgrade; `headers` go with the upgrade request.
    public init(url: URL, subprotocols: [String] = [], headers: [(name: String, value: String)] = [],
                maximumMessageSize: Int = 16 * 1024 * 1024, timeout: TimeInterval = 20, label: String = "caboose.websocket",
                queue: DispatchQueue? = nil) {
        self.url = url
        self.subprotocols = subprotocols
        self.headers = headers
        self.timeout = timeout
        self.reader = WebSocketReader(maximumMessageSize: maximumMessageSize)
        self.queue = queue ?? DispatchQueue(label: label)
    }

    /// Connects and upgrades; `handler` hears every event, on the socket's queue, until `.closed` or `close()`.
    public func open(_ handler: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            guard connection == nil, !ended else { return }
            self.handler = handler
            let request: Data
            do { request = try WebSocketHandshake.request(url: url, key: key, subprotocols: subprotocols, headers: headers) }
            catch { return finish(Close(failure: error.localizedDescription)) }
            guard let host = url.host, !host.isEmpty else { return finish(Close(failure: WebSocketHandshake.Failure.invalidAddress.localizedDescription)) }
            let secure = HTTP1Upgrade.isSecure(url)
            let port = url.port.flatMap { NWEndpoint.Port(rawValue: UInt16(clamping: $0)) } ?? (secure ? .https : .http)
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
            let parameters = NWParameters(tls: secure ? HTTP1Upgrade.tlsOptions() : nil, tcp: tcp)
            let trimmed = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            let connection = NWConnection(host: NWEndpoint.Host(trimmed), port: port, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    connection.send(content: request, completion: .contentProcessed { [weak self] error in
                        if let error { self?.finish(Close(failure: error.localizedDescription)) }
                    })
                    self.read()
                case .failed(let error), .waiting(let error):
                    // No waiting for connectivity: the caller decides when to try again.
                    self.finish(Close(failure: error.localizedDescription))
                case .cancelled:
                    self.finish(Close(failure: "The connection was cancelled."))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, !self.opened else { return }
                self.finish(Close(failure: "The host did not answer the connection in time."))
            }
        }
    }

    /// Sends a message; `completion` hears when it is handed to the network, or why not.
    public func send(_ message: Message, completion: (@Sendable (Error?) -> Void)? = nil) {
        queue.async { [self] in
            guard opened, !ended, let connection else {
                completion?(Close(failure: "The connection is not open."))
                return
            }
            let frame: Data = switch message {
            case .data(let data): WebSocketFrame.encode(.binary, payload: data, mask: WebSocketFrame.randomMask())
            case .string(let text): WebSocketFrame.encode(.text, payload: Data(text.utf8), mask: WebSocketFrame.randomMask())
            }
            connection.send(content: frame, completion: .contentProcessed { error in completion?(error) })
        }
    }

    /// Pings the host; `pong` hears its answer, or the error that ended the socket first.
    public func ping(_ pong: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard opened, !ended, let connection else { return pong(Close(failure: "The connection is not open.")) }
            pingCount &+= 1
            let payload = withUnsafeBytes(of: pingCount.bigEndian) { Data($0) }
            pongs.append((payload, pong))
            connection.send(content: WebSocketFrame.encode(.ping, payload: payload, mask: WebSocketFrame.randomMask()),
                            completion: .contentProcessed { _ in })
        }
    }

    /// Closes with `code` (1000 by default): the close frame goes out before the connection
    /// does. The handler hears nothing more, as it asked for the end.
    public func close(code: Int = 1000, reason: String? = nil) {
        queue.async { [self] in
            guard !ended else { return }
            handler = nil
            finish(Close(code: code, reason: reason), sending: opened ? WebSocketFrame.closePayload(code: code, reason: reason) : nil)
        }
    }

    /// Holds back reading and delivering messages while paused; the upgrade itself is always
    /// read. Pausing takes effect at once, from any thread: a handler that pauses while it
    /// handles a message gets no other until it resumes, and the socket reads no more from
    /// the network meanwhile, so TCP pushes back on the host.
    public func setReceivingPaused(_ paused: Bool) {
        let changed = pauseLock.withLock { () -> Bool in
            guard pausedFlag != paused else { return false }
            pausedFlag = paused
            return true
        }
        guard changed, !paused else { return }
        queue.async { [self] in
            deliver()
            read()
        }
    }

    private func read() {
        guard !ended, !(paused && opened), !reading, let connection else { return }
        reading = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, complete, error in
            guard let self else { return }
            self.reading = false
            guard !self.ended else { return }
            if let content, !content.isEmpty { self.received(content) }
            if self.ended { return }
            if let error { return self.finish(Close(failure: error.localizedDescription)) }
            if complete { return self.finish(Close(failure: "The host closed the connection.")) }
            self.read()
        }
    }

    private func received(_ bytes: Data) {
        guard opened else {
            head.append(bytes)
            do {
                guard let (response, consumed) = try WebSocketHandshake.parseResponse(head) else { return }
                if response.status != 101 { return finish(Close(refusedStatus: response.status)) }
                try WebSocketHandshake.validate(response, key: key, subprotocols: subprotocols)
                opened = true
                let rest = head.dropFirst(consumed)
                head = Data()
                handler?(.opened(response))
                if !rest.isEmpty { reader.append(Data(rest)) }
                deliver()
            } catch {
                finish(Close(failure: error.localizedDescription))
            }
            return
        }
        reader.append(bytes)
        deliver()
    }

    private func deliver() {
        while opened, !ended, !paused {
            let event: WebSocketReader.Event
            do {
                guard let next = try reader.next() else { return }
                event = next
            } catch let failure as WebSocketReader.Failure {
                return finish(Close(failure: failure.localizedDescription), sending: WebSocketFrame.closePayload(code: failure.closeCode))
            } catch {
                return finish(Close(failure: error.localizedDescription))
            }
            switch event {
            case .text(let text): handler?(.message(.string(text)))
            case .binary(let data): handler?(.message(.data(data)))
            case .ping(let payload):
                connection?.send(content: WebSocketFrame.encode(.pong, payload: payload, mask: WebSocketFrame.randomMask()),
                                 completion: .contentProcessed { _ in })
            case .pong(let payload):
                // A pong answers its own ping and every one before it; an unsolicited one, none.
                if let index = pongs.firstIndex(where: { $0.payload == payload }) {
                    let answered = pongs[...index]
                    pongs.removeFirst(index + 1)
                    for ping in answered { ping.answer(nil) }
                }
            case .close(let code, let reason):
                // Answer with the same code, then go.
                let echo = code.map { WebSocketFrame.sendableCode($0, echo: true) } ?? 1000
                return finish(Close(code: code, reason: reason), sending: WebSocketFrame.closePayload(code: echo))
            }
        }
    }

    /// How long a closing socket reads on for the peer's close before it cancels anyway.
    static let closeDrainLimit: TimeInterval = 2

    /// Reads until the peer's close frame, EOF or an error, then cancels.
    private func drain(_ connection: NWConnection, reader: WebSocketReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] content, _, complete, error in
            var reader = reader
            if let content { reader.append(content) }
            var closed = complete || error != nil
            while !closed, let event = try? reader.next() {
                if case .close = event { closed = true }
            }
            if closed { connection.cancel() } else { drain(connection, reader: reader) }
        }
    }

    deinit {
        // A socket dropped without `close()` must not leave its connection open.
        connection?.cancel()
    }

    /// Ends the socket once: a close frame with `payload` first when given, then the
    /// connection, cancelled once the frame is sent (or after a second regardless).
    private func finish(_ close: Close, sending payload: Data? = nil) {
        guard !ended else { return }
        ended = true
        let waiting = pongs
        pongs = []
        for ping in waiting { ping.answer(close) }
        if let connection {
            connection.stateUpdateHandler = nil
            if let payload {
                // Cancelling with unread bytes can reset the connection and lose the close frame
                // (a suspended GPU socket's 4001), so read on until the peer's close or EOF.
                let frame = WebSocketFrame.encode(.close, payload: payload, mask: WebSocketFrame.randomMask())
                // The socket stays alive until the drain ends, even once its owner lets it go.
                let limit = reader.maximumMessageSize
                connection.send(content: frame, completion: .contentProcessed { [self] error in
                    guard error == nil else { return connection.cancel() }
                    drain(connection, reader: WebSocketReader(maximumMessageSize: limit))
                })
                queue.asyncAfter(deadline: .now() + Self.closeDrainLimit) { connection.cancel() }
            } else {
                connection.cancel()
            }
        }
        handler?(.closed(close))
        handler = nil
    }
}
