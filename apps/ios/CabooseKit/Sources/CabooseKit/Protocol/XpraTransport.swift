import Foundation

/// Xpra packets over the host's `/v1/display` WebSocket relay. The relay is transparent:
/// frames carry Xpra's own packet framing, and message boundaries are not meaningful.
/// Sends are serialised; receives are delivered in order on `onEvent`.
public final class XpraTransport: @unchecked Sendable {
    public enum Event: Sendable {
        case opened
        case packets([XpraPacket])
        case closed(Error?)
    }

    private let stream: ByteStream
    private var parser = PacketParser() // on the stream's queue
    private var failed = false // on the stream's queue
    private let onEvent: @Sendable (Event) -> Void

    public init(url: URL, token: String, onEvent: @escaping @Sendable (Event) -> Void) {
        stream = WebSocketStream(url: url, token: token)
        self.onEvent = onEvent
    }

    public func open() {
        stream.open { [self] event in
            switch event {
            case .opened:
                onEvent(.opened)
            case .data(let data):
                guard !failed else { return }
                do {
                    let packets = try parser.append(data)
                    if !packets.isEmpty { onEvent(.packets(packets)) }
                } catch {
                    failed = true
                    stream.fail(error)
                }
            case .closed(let error):
                onEvent(.closed(error))
            }
        }
    }

    public func send(_ packet: XpraPacket) { stream.send(PacketFraming.encode(packet)) }

    public func close() { stream.close() }
}

public enum TransportError: Error, LocalizedError {
    case closed(code: Int)

    public var errorDescription: String? {
        switch self {
        case .closed(let code): "The display connection closed (code \(code))."
        }
    }
}
