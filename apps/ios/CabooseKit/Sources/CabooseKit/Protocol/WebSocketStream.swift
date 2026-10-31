import Foundation
import Network
import QuartzCore

/// A full-duplex byte stream over the host's `/v1/display` WebSocket relay, which carries
/// either display protocol.
///
/// The relay is transparent: message boundaries are not meaningful. Sends are serialised
/// on one queue, and events arrive in order on that same queue.
public protocol ByteStream: AnyObject, Sendable {
    func open(onEvent: @escaping @Sendable (ByteStreamEvent) -> Void)
    func send(_ data: Data)
    func close()
    /// Ends the stream because what arrived made no sense.
    func fail(_ error: Error)
    /// What has been handed to `send` and not yet sent, where the transport reports it.
    var sendBacklog: SendBacklog? { get }
}

public extension ByteStream {
    var sendBacklog: SendBacklog? { nil }
}

public enum ByteStreamEvent: Sendable {
    case opened
    case data(Data)
    case closed(Error?)
}

/// The display WebSocket over Network.framework with Nagle's algorithm off.
///
/// Input is small and frequent while pictures stream the other way. With Nagle on, each
/// small send waits for the acknowledgement of the previous one, and that acknowledgement
/// rides back behind the downstream pictures queued in the Wi-Fi access point: samples sent
/// every display refresh then leave in one burst hundreds of milliseconds later (measured:
/// 71 scroll samples sent over 583 ms arrived together after 657 ms). URLSession's WebSocket
/// task offers no way to set TCP_NODELAY, so the connection is built here.
public final class WebSocketStream: ByteStream, @unchecked Sendable {
    private let url: URL
    private let token: String
    private let queue = DispatchQueue(label: "caboose.display.socket")
    private var connection: NWConnection?
    private var closed = false
    private var opened = false
    private var onEvent: (@Sendable (ByteStreamEvent) -> Void)?
    private let backlogLock = NSLock()
    /// When each send not yet completed was handed over, oldest first (sends complete in order).
    private var pending: [CFTimeInterval] = []

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    public func open(onEvent: @escaping @Sendable (ByteStreamEvent) -> Void) {
        queue.async { [self] in
            guard connection == nil, !closed else { return }
            self.onEvent = onEvent
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            tcp.connectionTimeout = 20
            let secure = url.scheme?.lowercased() == "wss" || url.scheme?.lowercased() == "https"
            let parameters = NWParameters(tls: secure ? NWProtocolTLS.Options() : nil, tcp: tcp)
            let websocket = NWProtocolWebSocket.Options()
            websocket.autoReplyPing = true
            websocket.maximumMessageSize = 64 * 1024 * 1024
            websocket.setSubprotocols(["binary"])
            websocket.setAdditionalHeaders([("Authorization", "Bearer \(token)")])
            parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
            let connection = NWConnection(to: .url(url), using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if !self.opened { self.opened = true; self.onEvent?(.opened); self.receive() }
                case .failed(let error): self.finish(error)
                case .cancelled: self.finish(nil)
                case .waiting(let error): self.finish(error)  // no waiting for connectivity
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ data: Data) {
        backlogLock.withLock { pending.append(CACurrentMediaTime()) }
        queue.async { [self] in
            guard let connection, !closed else { return sent() }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true,
                            completion: .contentProcessed { [weak self] error in
                self?.sent()
                if let error { self?.finish(error) }
            })
        }
    }

    private func sent() {
        backlogLock.withLock { if !pending.isEmpty { pending.removeFirst() } }
    }

    public var sendBacklog: SendBacklog? {
        backlogLock.withLock {
            SendBacklog(count: pending.count, oldestMs: pending.first.map { (CACurrentMediaTime() - $0) * 1000 })
        }
    }

    public func close() {
        queue.async { [self] in
            if let connection, opened {
                // A normal close frame, then the connection goes.
                let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
                metadata.closeCode = .protocolCode(.normalClosure)
                let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
                connection.send(content: nil, contentContext: context, isComplete: true, completion: .idempotent)
            }
            finish(nil)
        }
    }

    public func fail(_ error: Error) {
        queue.async { [self] in finish(error) }
    }

    private func receive() {
        connection?.receiveMessage { [weak self] content, context, _, error in
            guard let self, !self.closed else { return }
            if let error { return self.finish(error) }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .close:
                let code = metadata.map { closeCode($0.closeCode) } ?? 1000
                return self.finish(code == 1000 ? nil : TransportError.closed(code: code))
            case .binary, .text:
                if let content, !content.isEmpty { self.onEvent?(.data(content)) }
            default:
                break
            }
            self.receive()
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        backlogLock.withLock { pending.removeAll() }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        onEvent?(.closed(error))
        onEvent = nil
    }
}

private func closeCode(_ code: NWProtocolWebSocket.CloseCode) -> Int {
    switch code {
    case .protocolCode(let value): Int(value.rawValue)
    case .applicationCode(let value): Int(value)
    case .privateCode(let value): Int(value)
    @unknown default: 1006
    }
}

public enum TransportError: Error, LocalizedError {
    case closed(code: Int)

    public var errorDescription: String? {
        switch self {
        case .closed(let code): "The display connection closed (code \(code))."
        }
    }
}
