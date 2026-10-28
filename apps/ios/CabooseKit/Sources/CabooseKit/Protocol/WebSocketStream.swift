import Foundation

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
}

public enum ByteStreamEvent: Sendable {
    case opened
    case data(Data)
    case closed(Error?)
}

public final class WebSocketStream: NSObject, ByteStream, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let queue = DispatchQueue(label: "caboose.display.socket")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var onEvent: (@Sendable (ByteStreamEvent) -> Void)?

    public init(url: URL, token: String) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.timeoutInterval = 20
        self.request = request
    }

    public func open(onEvent: @escaping @Sendable (ByteStreamEvent) -> Void) {
        queue.async { [self] in
            guard task == nil else { return }
            self.onEvent = onEvent
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

    public func send(_ data: Data) {
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

    public func fail(_ error: Error) {
        queue.async { [self] in
            task?.cancel(with: .protocolError, reason: nil)
            finish(error)
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .failure(let error):
                self.finish(error)
            case .success(let message):
                switch message {
                case .data(let bytes): self.onEvent?(.data(bytes))
                case .string(let text): self.onEvent?(.data(Data(text.utf8)))
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        onEvent?(.closed(error))
        onEvent = nil
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        onEvent?(.opened)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(closeCode == .normalClosure ? nil : TransportError.closed(code: closeCode.rawValue))
    }
}
