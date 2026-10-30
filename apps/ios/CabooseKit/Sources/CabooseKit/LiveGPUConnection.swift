import Foundation

public enum LiveGPUError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidProtocol, compression, textMessage, messageTooLarge, overflow
    case notOpen, closed, missingNativeBinding, drainTimedOut
}

/// One-shot transport. A reconnect always creates a new instance; no queued bytes survive it.
public protocol LiveGPUTransport: AnyObject, Sendable {
    func open(_ event: @escaping @Sendable (LiveGPUTransportEvent) -> Void)
    @discardableResult func send(_ bytes: Data) -> Bool
    func close()
}

public enum LiveGPUTransportEvent: Sendable {
    case opened, bytes(Data), closed(Error?)
}

/// Counts retained work, including running work. Revocation never releases a running permit.
final class LiveGPUBudget: @unchecked Sendable {
    static let messageLimit = 256 * 1024
    static let byteLimit = 1024 * 1024
    static let countLimit = 64
    private let lock = NSLock()
    private var bytes = 0
    private var count = 0
    private var revoked = false
    func admit(_ size: Int) -> LiveGPUError? {
        lock.withLock {
            guard !revoked else { return .closed }
            guard size >= 0, size <= Self.messageLimit else { revoked = true; return .messageTooLarge }
            guard count < Self.countLimit, size <= Self.byteLimit - bytes else {
                revoked = true; return .overflow
            }
            bytes += size; count += 1
            return nil
        }
    }
    func release(_ size: Int) { lock.withLock { bytes -= size; count -= 1 } }
    func revoke() { lock.withLock { revoked = true } }
    var active: Bool { lock.withLock { !revoked } }
    var retained: (bytes: Int, count: Int) { lock.withLock { (bytes, count) } }
}

/// Dedicated live socket, independent of the display/replay transport. Events are ordered
/// on a private network queue; consumers must admit and dispatch blocking work elsewhere.
public final class LiveGPUConnection: NSObject, LiveGPUTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    public static let subprotocolName = "caboose.gpu.live.v1"
    private let request: URLRequest
    private let queue = DispatchQueue(label: "caboose.gpu.network")
    private let budget = LiveGPUBudget()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var event: (@Sendable (LiveGPUTransportEvent) -> Void)?
    private var started = false
    private var ended = false
    private var ready = false
    private var pending: [Data] = []
    private var sending = false

    /// Only the existing phone credential goes to the host. Executor and runtime identity
    /// are host authority and are deliberately absent from this API.
    public init(hostURL: URL, phoneToken: String) throws {
        request = try Self.makeRequest(hostURL: hostURL, phoneToken: phoneToken)
    }

    static func makeRequest(hostURL: URL, phoneToken: String) throws -> URLRequest {
        guard var url = URLComponents(url: hostURL, resolvingAgainstBaseURL: false),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              ["http", "https", "ws", "wss"].contains(url.scheme ?? ""),
              !phoneToken.isEmpty, !phoneToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw LiveGPUError.invalidEndpoint
        }
        url.scheme = ["https", "wss"].contains(url.scheme!) ? "wss" : "ws"
        url.path = "/v1/gpu"
        guard let endpoint = url.url else { throw LiveGPUError.invalidEndpoint }
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue("Bearer \(phoneToken)", forHTTPHeaderField: "Authorization")
        request.setValue(subprotocolName, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    static func validateUpgrade(selected: String?, extensions: String?) throws {
        guard selected == subprotocolName else { throw LiveGPUError.invalidProtocol }
        guard extensions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else {
            throw LiveGPUError.compression
        }
    }

    static func binaryBytes(_ message: URLSessionWebSocketTask.Message) throws -> Data {
        guard case .data(let data) = message else { throw LiveGPUError.textMessage }
        guard data.count <= LiveGPUBudget.messageLimit else { throw LiveGPUError.messageTooLarge }
        return data
    }

    public func open(_ event: @escaping @Sendable (LiveGPUTransportEvent) -> Void) {
        queue.async { [self] in
            guard !started, !ended else { return }
            started = true; self.event = event
            guard budget.active else { finish(LiveGPUError.closed); return }
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            let delegate = OperationQueue()
            delegate.underlyingQueue = queue; delegate.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: delegate)
            let task = session.webSocketTask(with: request)
            task.maximumMessageSize = LiveGPUBudget.messageLimit
            self.session = session; self.task = task
            task.resume()
            // Receive starts only after exact subprotocol validation.
        }
    }

    @discardableResult public func send(_ bytes: Data) -> Bool {
        // Admission happens before a closure can capture Data, even from concurrent producers.
        if let error = budget.admit(bytes.count) {
            if error != .closed { queue.async { [self] in finish(error) } }
            return false
        }
        queue.async { [self] in
            guard !ended, budget.active else { budget.release(bytes.count); return }
            guard ready else { budget.release(bytes.count); finish(LiveGPUError.notOpen); return }
            pending.append(bytes); pump()
        }
        return true
    }

    public func close() {
        budget.revoke()
        queue.async { [self] in finish(nil) }
    }

    private func pump() {
        guard !ended, budget.active, !sending, let task, !pending.isEmpty else { return }
        let data = pending.removeFirst()
        sending = true
        let size = data.count
        task.send(.data(data)) { [self] error in
            queue.async { [self] in
                budget.release(size); sending = false
                guard !ended, budget.active else { return }
                if let error { finish(error) } else { pump() }
            }
        }
    }

    private func receive() {
        guard !ended, budget.active, let task else { return }
        task.receive { [self] result in
            queue.async { [self] in
                guard !ended, budget.active else { return }
                switch result {
                case .success(let message):
                    do { event?(.bytes(try Self.binaryBytes(message))); receive() }
                    catch { finish(error) }
                case .failure(let error): finish(error)
                }
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !ended else { return }
        ended = true; ready = false; budget.revoke()
        for data in pending { budget.release(data.count) }
        pending.removeAll()
        task?.cancel(with: error == nil ? .normalClosure : .policyViolation, reason: nil)
        session?.invalidateAndCancel()
        task = nil; session = nil
        event?(.closed(error)); event = nil
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol selected: String?) {
        guard webSocketTask === task, !ended, budget.active else { return }
        do {
            let response = webSocketTask.response as? HTTPURLResponse
            try Self.validateUpgrade(selected: selected, extensions: response?.value(forHTTPHeaderField: "Sec-WebSocket-Extensions"))
            ready = true; event?(.opened); receive()
        } catch { finish(error) }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        finish(closeCode == .normalClosure ? nil : LiveGPUError.closed)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        finish(error)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
