import Foundation

public enum LiveGPUError: Error, Equatable, Sendable {
    case invalidEndpoint, invalidProtocol, compression, textMessage, messageTooLarge, overflow
    case notOpen, closed, missingNativeBinding, drainTimedOut
    /// The host holds no executor for the resume credential (HTTP 410).
    case resumeRefused
    /// No pong from the host for longer than the relay's own silence limit.
    case silent
    /// Native cleanup had not returned in time; it goes on, and the executor counts as ended.
    case cleanupTimedOut
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

/// A transport whose receiving the session holds back while its decoder is behind, so the
/// host waits (its relay pauses the guest until the phone reads) instead of the phone's
/// queue overflowing and ending the executor.
protocol LiveGPUReceiveFlow: AnyObject {
    func setReceivingPaused(_ paused: Bool)
}

/// Counts retained logical work, including running work and any coalesced send
/// scratch buffer. This is retained logical byte accounting, not an allocator or
/// physical RSS proof. Revocation never releases a running permit.
final class LiveGPUBudget: @unchecked Sendable {
    static let messageLimit = 256 * 1024
    /// Outbound work the phone may queue while the network or host is slower than the
    /// decoder's replies: replies leave the native bridge in pieces of up to 64 KiB, so a busy
    /// stream (video, a pipeline compile backlog) queues many small messages.
    static let byteLimit = 8 * 1024 * 1024
    static let countLimit = 2048
    /// Receiving pauses above these and resumes below a quarter of the limits, far from the
    /// limits themselves: a paused socket delivers at most the message it already holds.
    static let pauseBytes = byteLimit / 2
    static let pauseCount = countLimit / 2
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
    /// Whether retained work is past the pause watermark.
    var full: Bool { lock.withLock { bytes >= Self.pauseBytes || count >= Self.pauseCount } }
    /// Whether retained work has drained below the resume watermark.
    var drained: Bool { lock.withLock { bytes <= Self.pauseBytes / 2 && count <= Self.pauseCount / 2 } }
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
public final class LiveGPUConnection: NSObject, LiveGPUResumeSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    public static let subprotocolName = "caboose.gpu.live.v1"
    /// Capabilities of this app's native decoder that a computer may use: it registers
    /// objects under Vulkan handles the guest assigns (patch 0026), including descriptor
    /// sets and command buffers (patch 0027), serves the completion feed (patch 0028), runs
    /// presents ordered behind device-stream ORDER marks, and keeps the computer's shader
    /// modules to take later ones by hash (docs/gpu-live.md, "Shader cache"), and resumes
    /// its executor on a new socket ("Resuming an executor"), and decodes commands sent as one
    /// zstd stream ("Optional bounded command compression"), keeps uploaded data by hash
    /// ("Upload cache"), and registers buffer views under guest-assigned handles.
    static let features = "guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline"
    static let resumeHeader = "X-Caboose-GPU-Resume"
    /// A resume attempt waits this long for its upgrade; the next follows at once.
    static let resumeTimeout: TimeInterval = 3
    /// The host relay ends a phone silent for 3 s; one that hears no pong for as long has
    /// lost the host, and a resumable executor reconnects instead of waiting on TCP. Any other
    /// executor ends after 10 s without one, so a socket that died silently cannot keep it.
    static let silenceLimit: TimeInterval = 3
    static let plainSilenceLimit: TimeInterval = 10
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
    /// Pings the host every second from its own queue, so the relay sees this phone alive
    /// even while delivery to a busy decoder holds back receiving (and so pong replies).
    private let pingQueue = DispatchQueue(label: "caboose.gpu.ping")
    private var pinger: DispatchSourceTimer?
    private var closeCode = URLSessionWebSocketTask.CloseCode.normalClosure
    /// A resume attempt: its upgrade must complete within `resumeTimeout`. The request's own
    /// timeout stays as it is, since URLSession also applies it to an open socket's idle time.
    private var resuming = false
    private let credentialLock = NSLock()
    private var credential: String? // set on queue before .opened, under credentialLock
    /// The host's resume credential from the upgrade response; nil when it issued none.
    var resumeCredential: String? { credentialLock.withLock { credential } }
    var queuedMessages: Int { budget.retained.count }
    /// Seconds since the host was last heard, counting time the phone slept (a locked screen).
    var silence: TimeInterval {
        let heard = credentialLock.withLock { heardAt }
        return Double(Self.clock() &- heard) / 1e9
    }
    private var heardAt = LiveGPUConnection.clock() // under credentialLock
    /// Receiving held back by the session (on `queue`), and whether a receive is outstanding.
    private var receivePaused = false
    private var receiving = false
    private func heard() { credentialLock.withLock { heardAt = Self.clock() } }
    private static func clock() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }

    /// Only the existing phone credential goes to the host. Executor and runtime identity
    /// are host authority and are deliberately absent from this API.
    public init(hostURL: URL, phoneToken: String, route: ComputerRoute = .unscoped) throws {
        request = try Self.makeRequest(hostURL: hostURL, phoneToken: phoneToken, route: route)
    }

    /// A socket for a validated request, resuming the host's executor when given its credential.
    init(request: URLRequest, resumeCredential: String?) {
        var request = request
        if let resumeCredential, Self.validCredential(resumeCredential) {
            request.setValue(resumeCredential, forHTTPHeaderField: Self.resumeHeader)
            resuming = true
        }
        self.request = request
    }

    /// 32 bytes in unpadded base64url.
    static func validCredential(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy { byte in
            (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2d || byte == 0x5f
        }
    }

    /// The `/v1/gpu` upgrade, at the computer's scoped route for a host sign-in.
    static func makeRequest(hostURL: URL, phoneToken: String, route: ComputerRoute = .unscoped) throws -> URLRequest {
        guard var url = URLComponents(url: hostURL, resolvingAgainstBaseURL: false),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              ["http", "https", "ws", "wss"].contains(url.scheme ?? ""),
              !phoneToken.isEmpty, !phoneToken.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw LiveGPUError.invalidEndpoint
        }
        url.scheme = ["https", "wss"].contains(url.scheme!) ? "wss" : "ws"
        url.path = route.path("/v1/gpu")
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
            if resuming {
                queue.asyncAfter(deadline: .now() + Self.resumeTimeout) { [weak self] in
                    guard let self, !self.ended, !self.ready else { return }
                    LiveGPUResumableTransport.log("socket upgrade deadline")
                    self.finish(LiveGPUError.silent)
                }
            }
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

    func close(abnormally error: Error) {
        budget.revoke()
        queue.async { [self] in finish(error) }
    }

    func closeSuspended() {
        budget.revoke()
        queue.async { [self] in
            closeCode = URLSessionWebSocketTask.CloseCode(rawValue: 4001) ?? .goingAway
            finish(nil)
        }
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
        guard !ended, budget.active, !receivePaused, !receiving, let task else { return }
        receiving = true
        task.receive { [self] result in
            queue.async { [self] in
                receiving = false
                guard !ended, budget.active else { return }
                switch result {
                case .success(let message):
                    heard() // any message proves the host is there
                    do { event?(.bytes(try Self.binaryBytes(message))); receive() }
                    catch { finish(error) }
                case .failure(let error): finish(error)
                }
            }
        }
    }

    func setReceivingPaused(_ paused: Bool) {
        queue.async { [self] in
            guard receivePaused != paused else { return }
            receivePaused = paused
            if !paused && ready { receive() }
        }
    }

    private func finish(_ error: Error?) {
        guard !ended else { return }
        ended = true; ready = false; budget.revoke()
        pinger?.cancel(); pinger = nil
        outbound.discardPending()
        task?.cancel(with: error == nil ? closeCode : .policyViolation, reason: nil)
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
            let issued = response?.value(forHTTPHeaderField: Self.resumeHeader).flatMap { Self.validCredential($0) ? $0 : nil }
            credentialLock.withLock { credential = issued }
            ready = true; event?(.opened); receive()
            heard()
            let timer = DispatchSource.makeTimerSource(queue: pingQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self, weak webSocketTask] in
                guard let self, let webSocketTask else { return }
                webSocketTask.sendPing { [weak self] error in
                    guard let self, error == nil else { return }
                    self.heard()
                }
                self.queue.async {
                    let limit = self.resumeCredential != nil ? Self.silenceLimit : Self.plainSilenceLimit
                    guard !self.ended,
                          self.silence > limit else { return }
                    LiveGPUResumableTransport.log("socket silent limit=\(limit)")
                    self.finish(LiveGPUError.silent)
                }
            }
            timer.resume(); pinger = timer
        } catch { finish(error) }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        LiveGPUResumableTransport.log("socket peer close code=\(closeCode.rawValue)")
        finish(closeCode == .normalClosure ? nil : LiveGPUError.closed)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        LiveGPUResumableTransport.log("socket completed ready=\(ready ? 1 : 0) status=\((task.response as? HTTPURLResponse)?.statusCode ?? 0) error=\(error.map { String(describing: $0) } ?? "none")")
        if !ready, (task.response as? HTTPURLResponse)?.statusCode == 410 {
            finish(LiveGPUError.resumeRefused); return
        }
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

extension LiveGPUConnection: LiveGPUReceiveFlow {}
