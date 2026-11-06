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
    /// Set the moment `close()` is called, so no event is delivered after it returns.
    private let closing = NSLock()
    private var closedByClient = false

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

    /// Closes without ending the session, which stays on the computer to reattach to. No
    /// event is delivered once this returns, even one already on its way.
    public func close() {
        closing.withLock { closedByClient = true }
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
        guard !ended, !closing.withLock({ closedByClient }) else { return }
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

/// `TerminalTransport` over the host's `/v1/terminal` WebSocket (`HTTP1WebSocket`).
public final class WebSocketTerminalTransport: TerminalTransport, @unchecked Sendable {
    private let socket: HTTP1WebSocket

    /// `timeout` bounds the upgrade, which can include waking the computer.
    public init(url: URL, token: String, timeout: TimeInterval = 120) {
        socket = HTTP1WebSocket(url: url, headers: [("Authorization", "Bearer \(token)")],
                                maximumMessageSize: 4 * 1024 * 1024, timeout: timeout, label: "caboose.terminal.socket")
    }

    public func open(onEvent: @escaping @Sendable (TerminalTransportEvent) -> Void) {
        socket.open { event in
            switch event {
            case .opened: break
            case .message(.data(let data)): onEvent(.message(.data(data)))
            case .message(.string(let text)): onEvent(.message(.text(text)))
            case .closed(let close):
                if let status = close.refusedStatus { onEvent(.refused(status: status)) }
                else if let failure = close.failure { onEvent(.failed(failure)) }
                else { onEvent(.closed(code: close.code ?? 1005, reason: close.reason)) }
            }
        }
    }

    public func send(_ message: TerminalTransportMessage, completion: @escaping @Sendable (Error?) -> Void) {
        switch message {
        case .data(let data): socket.send(.data(data), completion: completion)
        case .text(let text): socket.send(.string(text), completion: completion)
        }
    }

    public func close() { socket.close() }
}
