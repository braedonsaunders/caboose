import Foundation

/// A WebSocket that keeps text and binary messages apart and reports how it closed.
public protocol TerminalTransport: AnyObject, Sendable {
    func open(onEvent: @escaping @Sendable (TerminalTransportEvent) -> Void)
    /// Sends in order; `completion` runs once the message is handed to the network.
    func send(_ message: TerminalTransportMessage, completion: @escaping @Sendable (Error?) -> Void)
    func close()
}

public enum TerminalTransportMessage: Equatable, Sendable {
    case data(Data)
    case text(String)
}

public enum TerminalTransportEvent: Sendable {
    case message(TerminalTransportMessage)
    /// The upgrade was refused with an HTTP status.
    case refused(status: Int)
    case closed(code: Int, reason: String?)
    case failed(String)
}

/// What a connection reports, in order, on its own queue.
public enum TerminalEvent: Sendable {
    case connected(TerminalHello)
    case output(Data)
    case ended(TerminalEnd)
}

/// One connection to one session. It tracks how much of the session's output it has
/// received, so the next connection can continue from there (`offset`). Input is sent in
/// order, and no more than `inputWindow` bytes are in flight: past that, input waits.
public final class TerminalConnection: @unchecked Sendable {
    public let queue = DispatchQueue(label: "caboose.terminal.connection")
    private let transport: TerminalTransport
    private var onEvent: (@Sendable (TerminalEvent) -> Void)?
    private var hello: TerminalHello?
    private var exit: (code: Int?, signal: Int?)?
    private var ended = false
    private var received = 0
    private var pendingInput: [Data] = []
    private var inFlight = 0
    private var pendingResize: (Int, Int)?
    private let inputWindow = 256 * 1024

    public init(transport: TerminalTransport) {
        self.transport = transport
    }

    /// The session this connection is attached to, once the host has said hello.
    public var session: String? { queue.sync { hello?.session } }
    /// The output offset this client holds: where a reattach continues.
    public var offset: Int { queue.sync { received } }

    public func start(onEvent: @escaping @Sendable (TerminalEvent) -> Void) {
        queue.async { [self] in
            self.onEvent = onEvent
            transport.open { [weak self] event in self?.queue.async { self?.handle(event) } }
        }
    }

    public func send(input: Data) {
        guard !input.isEmpty else { return }
        queue.async { [self] in
            guard !ended else { return }
            pendingInput.append(input)
            flushInput()
        }
    }

    /// Resizes are coalesced: only the latest size waiting to go is sent.
    public func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            guard !ended else { return }
            let first = pendingResize == nil
            pendingResize = (columns, rows)
            if first, hello != nil { sendResize() }
        }
    }

    public func hangup() {
        queue.async { [self] in
            guard !ended, hello != nil else { return }
            transport.send(.text(TerminalClientMessage.hangup.json)) { _ in }
        }
    }

    /// Closes without ending the session, which stays on the computer to reattach to.
    public func close() {
        queue.async { [self] in
            guard !ended else { return }
            transport.close()
            finish(.dropped(nil), notify: false)
        }
    }

    private func sendResize() {
        guard let (columns, rows) = pendingResize else { return }
        transport.send(.text(TerminalClientMessage.resize(columns: columns, rows: rows).json)) { [weak self] _ in
            self?.queue.async {
                guard let self else { return }
                if let latest = self.pendingResize, latest == (columns, rows) { self.pendingResize = nil } else { self.sendResize() }
            }
        }
    }

    private func flushInput() {
        guard hello != nil else { return }
        while !pendingInput.isEmpty, inFlight < inputWindow {
            let chunk = pendingInput.removeFirst()
            inFlight += chunk.count
            transport.send(.data(chunk)) { [weak self] error in
                self?.queue.async {
                    guard let self else { return }
                    self.inFlight -= chunk.count
                    if let error { self.transport.close(); self.finish(.dropped(error.localizedDescription)) } else { self.flushInput() }
                }
            }
        }
    }

    private func handle(_ event: TerminalTransportEvent) {
        guard !ended else { return }
        switch event {
        case .message(.text(let text)):
            switch TerminalServerMessage(json: text) {
            case .hello(let hello)? where self.hello == nil:
                self.hello = hello
                received = hello.offset
                onEvent?(.connected(hello))
                // A size chosen before the hello goes now; the host has the URL's otherwise.
                if pendingResize != nil { sendResize() }
                flushInput()
            case .exit(let code, let signal)? where hello != nil:
                exit = (code, signal)
            default:
                transport.close()
                finish(.dropped("The computer sent an unexpected terminal message."))
            }
        case .message(.data(let data)):
            guard hello != nil else {
                transport.close()
                finish(.dropped("The computer sent output before its hello."))
                return
            }
            received += data.count
            onEvent?(.output(data))
        case .refused(let status):
            finish(TerminalEnd(httpStatus: status))
        case .closed(let code, let reason):
            if let exit { finish(.exited(code: exit.code, signal: exit.signal)) } else { finish(TerminalEnd(closeCode: code, reason: reason)) }
        case .failed(let message):
            if let exit { finish(.exited(code: exit.code, signal: exit.signal)) } else { finish(.dropped(message)) }
        }
    }

    private func finish(_ end: TerminalEnd, notify: Bool = true) {
        guard !ended else { return }
        ended = true
        pendingInput.removeAll()
        if notify { onEvent?(.ended(end)) }
        onEvent = nil
    }
}

/// `TerminalTransport` over URLSession.
public final class URLSessionTerminalTransport: NSObject, TerminalTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let request: URLRequest
    private let queue = DispatchQueue(label: "caboose.terminal.socket")
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var onEvent: (@Sendable (TerminalTransportEvent) -> Void)?
    private var done = false

    /// `timeout` bounds the upgrade, which can include waking the computer.
    public init(url: URL, token: String, timeout: TimeInterval = 120) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        self.request = request
    }

    public func open(onEvent: @escaping @Sendable (TerminalTransportEvent) -> Void) {
        queue.async { [self] in
            guard task == nil, !done else { return }
            self.onEvent = onEvent
            let configuration = URLSessionConfiguration.default
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            let delegateQueue = OperationQueue()
            delegateQueue.underlyingQueue = queue
            delegateQueue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = 4 * 1024 * 1024
            self.session = session
            self.task = task
            task.resume()
            receive()
        }
    }

    public func send(_ message: TerminalTransportMessage, completion: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            guard let task, !done else { completion(URLError(.networkConnectionLost)); return }
            let outgoing: URLSessionWebSocketTask.Message = switch message {
            case .data(let data): .data(data)
            case .text(let text): .string(text)
            }
            task.send(outgoing, completionHandler: completion)
        }
    }

    public func close() {
        queue.async { [self] in
            guard !done else { return }
            task?.cancel(with: .normalClosure, reason: nil)
            done = true
            session?.invalidateAndCancel()
            onEvent = nil
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, !self.done else { return }
            switch result {
            case .success(.data(let data)): self.onEvent?(.message(.data(data))); self.receive()
            case .success(.string(let text)): self.onEvent?(.message(.text(text))); self.receive()
            case .success: self.receive()
            case .failure(let error):
                // The close frame's code arrives through the delegate, sometimes just after.
                self.queue.asyncAfter(deadline: .now() + 0.25) { self.failed(error) }
            }
        }
    }

    private func failed(_ error: Error) {
        guard !done, let task else { return }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            finish(.refused(status: response.statusCode))
        } else if task.closeCode != .invalid {
            finish(.closed(code: task.closeCode.rawValue, reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) }))
        } else {
            finish(.failed(error.localizedDescription))
        }
    }

    private func finish(_ event: TerminalTransportEvent) {
        guard !done else { return }
        done = true
        onEvent?(event)
        onEvent = nil
        session?.invalidateAndCancel()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.closed(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) }))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
            finish(.refused(status: response.statusCode))
        } else {
            queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.failed(error) }
        }
    }
}
