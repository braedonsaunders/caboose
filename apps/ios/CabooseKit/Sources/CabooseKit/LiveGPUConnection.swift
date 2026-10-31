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

/// Counts retained logical work, including running work and any coalesced send
/// scratch buffer. This is retained logical byte accounting, not an allocator or
/// physical RSS proof. Revocation never releases a running permit.
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
    /// Reserves destination scratch bytes for optional ready-prefix coalescing
    /// before allocating the combined Data buffer. Failure never revokes the budget.
    func reserveScratch(_ size: Int) -> Bool {
        lock.withLock {
            guard !revoked, size >= 0, size <= Self.byteLimit - bytes else { return false }
            bytes += size
            return true
        }
    }
    func release(_ size: Int, count releasedCount: Int = 1) {
        lock.withLock {
            precondition(size >= 0 && releasedCount >= 0 && size <= bytes && releasedCount <= count)
            bytes -= size; count -= releasedCount
        }
    }
    func revoke() { lock.withLock { revoked = true } }
    var active: Bool { lock.withLock { !revoked } }
    var retained: (bytes: Int, count: Int) { lock.withLock { (bytes, count) } }
}

/// Serial outbound queue helper that coalesces a ready FIFO prefix into one
/// WebSocket binary message without a timer while conservatively retaining both
/// the original permits and the destination scratch permit until send completion.
final class LiveGPUOutboundQueue {
    struct Batch {
        let data: Data
        let originalBytes: Int
        let scratchBytes: Int
        let count: Int
        var totalRetainedBytes: Int { originalBytes + scratchBytes }
    }

    private let budget: LiveGPUBudget
    private var pending: [Data] = []
    private var inFlight: Batch?

    init(budget: LiveGPUBudget) {
        self.budget = budget
    }

    var isSending: Bool { inFlight != nil }
    var isEmpty: Bool { pending.isEmpty }
    var pendingCount: Int { pending.count }

    func enqueue(_ bytes: Data) {
        pending.append(bytes)
    }

    func nextBatch() -> Batch? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        let first = pending.removeFirst()
        guard !pending.isEmpty else {
            let batch = Batch(data: first, originalBytes: first.count, scratchBytes: 0, count: 1)
            inFlight = batch
            return batch
        }
        var total = first.count
        var extraCount = 0
        let maxExtra = min(pending.count, LiveGPUBudget.countLimit - 1)
        while extraCount < maxExtra {
            let nextSize = pending[extraCount].count
            if total + nextSize > LiveGPUBudget.messageLimit { break }
            total += nextSize
            extraCount += 1
        }
        guard extraCount > 0, budget.reserveScratch(total) else {
            let batch = Batch(data: first, originalBytes: first.count, scratchBytes: 0, count: 1)
            inFlight = batch
            return batch
        }
        var combined = Data(count: total)
        var offset = 0
        combined.withUnsafeMutableBytes { dest in
            let base = dest.baseAddress
            if first.count > 0 {
                first.withUnsafeBytes { src in
                    if let dstBase = base, let srcBase = src.baseAddress {
                        memcpy(dstBase.advanced(by: offset), srcBase, first.count)
                    }
                }
                offset += first.count
            }
            for _ in 0..<extraCount {
                let part = pending.removeFirst()
                if part.count > 0 {
                    part.withUnsafeBytes { src in
                        if let dstBase = base, let srcBase = src.baseAddress {
                            memcpy(dstBase.advanced(by: offset), srcBase, part.count)
                        }
                    }
                    offset += part.count
                }
            }
        }
        precondition(offset == total)
        let batch = Batch(data: combined, originalBytes: total, scratchBytes: total, count: 1 + extraCount)
        inFlight = batch
        return batch
    }

    /// Releases the in-flight batch's original bytes/count plus any scratch
    /// reservation exactly once. Safe if called after discardPending().
    func completeInFlight() -> Bool {
        guard let batch = inFlight else { return false }
        inFlight = nil
        budget.release(batch.totalRetainedBytes, count: batch.count)
        return true
    }

    /// Releases queued pending permits only; any in-flight batch remains
    /// accounted until its send completion callback invokes completeInFlight().
    func discardPending() {
        for data in pending { budget.release(data.count) }
        pending.removeAll()
    }
}

/// Dedicated live socket, independent of the display/replay transport. Events are ordered
/// on a private network queue; consumers must admit and dispatch blocking work elsewhere.
public final class LiveGPUConnection: NSObject, LiveGPUTransport, URLSessionWebSocketDelegate, @unchecked Sendable {
    public static let subprotocolName = "caboose.gpu.live.v1"
    /// Capabilities of this app's native decoder that a computer may use: it registers
    /// objects under Vulkan handles the guest assigns (patch 0026), including descriptor
    /// sets and command buffers (patch 0027), serves the completion feed (patch 0028), and
    /// runs presents ordered behind device-stream ORDER marks.
    static let features = "guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images"
    private let request: URLRequest
    private let queue = DispatchQueue(label: "caboose.gpu.network")
    private let budget = LiveGPUBudget()
    private lazy var outbound = LiveGPUOutboundQueue(budget: budget)
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var event: (@Sendable (LiveGPUTransportEvent) -> Void)?
    private var started = false
    private var ended = false
    private var ready = false

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
        request.setValue(features, forHTTPHeaderField: "X-Caboose-GPU-Features")
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
            outbound.enqueue(bytes); pump()
        }
        return true
    }

    public func close() {
        budget.revoke()
        queue.async { [self] in finish(nil) }
    }

    private func pump() {
        guard !ended, budget.active, !outbound.isSending, let task,
              let batch = outbound.nextBatch() else { return }
        task.send(.data(batch.data)) { [self] error in
            queue.async { [self] in
                _ = outbound.completeInFlight()
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
        outbound.discardPending()
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
        // Only didCloseWith(.normalClosure) proves a normal peer close.
        // Completion without that receipt cannot release an executor lease.
        finish(error ?? LiveGPUError.closed)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
