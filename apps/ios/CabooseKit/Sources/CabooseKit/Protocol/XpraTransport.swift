import Foundation

/// A full-duplex Xpra byte stream over the host's `/v1/display` WebSocket relay.
///
/// The relay is transparent: frames carry Xpra's own packet framing, and message
/// boundaries are not meaningful. Sends are serialised on the task; receives are
/// delivered in order on `onPackets`.
public final class XpraTransport: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        case opened
        case packets([XpraPacket])
        case closed(Error?)
    }

    private let request: URLRequest
    private let queue = DispatchQueue(label: "caboose.xpra.transport")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var parser = PacketParser()
    private var closed = false
    private let onEvent: @Sendable (Event) -> Void

    public init(url: URL, token: String, onEvent: @escaping @Sendable (Event) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.timeoutInterval = 20
        self.request = request
        self.onEvent = onEvent
    }

    public func open() {
        queue.async { [self] in
            guard task == nil else { return }
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 20
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = 64 * 1024 * 1024
            self.session = session
            self.task = task
            task.resume()
            receive()
        }
    }

    public func send(_ packet: XpraPacket) {
        let data = PacketFraming.encode(packet)
        queue.async { [self] in
            guard let task, !closed else { return }
            task.send(.data(data)) { [weak self] error in
                if let error { self?.finish(error) }
            }
        }
    }

    public func close() {
        queue.async { [self] in
            task?.cancel(with: .normalClosure, reason: nil)
            finish(nil)
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finish(error)
            case .success(let message):
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: data = Data()
                }
                do {
                    let packets = try self.parser.append(data)
                    if !packets.isEmpty { self.onEvent(.packets(packets)) }
                    self.receive()
                } catch {
                    self.task?.cancel(with: .protocolError, reason: nil)
                    self.finish(error)
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        onEvent(.closed(error))
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        onEvent(.opened)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(closeCode == .normalClosure ? nil : TransportError.closed(code: closeCode.rawValue))
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
