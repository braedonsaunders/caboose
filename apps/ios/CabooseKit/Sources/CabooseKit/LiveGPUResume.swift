import Foundation
import Security

/// One WebSocket under a resumable executor transport. `LiveGPUConnection` is the production
/// socket; each reconnect opens a new one carrying the latest resume credential.
protocol LiveGPUResumeSocket: LiveGPUTransport {
    /// The host's resume credential from this socket's upgrade response, once opened.
    var resumeCredential: String? { get }
    /// Messages this socket has accepted but not yet finished sending.
    var queuedMessages: Int { get }
    /// Closes with code 4001: the executor is suspended and the host holds it for longer.
    func closeSuspended()
    /// Ends this socket as lost, reporting `error`.
    func close(abnormally error: Error)
    /// Seconds since the host was last heard on this socket (a pong or a message).
    var silence: TimeInterval { get }
}

/// The resume envelopes of docs/gpu-live.md ("Resuming an executor"): ACK and RESUME live
/// outside the directional sequence (sequence 0) and never reach the envelope decoder.
enum LiveGPUResumeWire {
    static let ack: UInt16 = 40
    static let resume: UInt16 = 41
    static let ackPayload = 8
    static let resumePayload = 32

    struct Header: Equatable {
        let kind: UInt16
        let length: Int
        let executor: Data
        let generation: UInt64
        let process: UInt64
        let stream: UInt64
        let sequence: UInt64
    }

    /// The header of a message that is exactly one whole CGLV envelope, else nil.
    static func header(_ message: Data) -> Header? {
        guard message.count >= LiveGPUEnvelope.headerSize else { return nil }
        let base = message.startIndex
        func number<T: FixedWidthInteger>(_ at: Int, _: T.Type) -> T {
            (0..<MemoryLayout<T>.size).reduce(T(0)) { $0 | T(message[base + at + $1]) << ($1 * 8) }
        }
        guard message[base..<(base + 4)].elementsEqual([0x43, 0x47, 0x4c, 0x56]),
              number(4, UInt16.self) == 1, number(12, UInt32.self) == 0 else { return nil }
        let length = Int(number(8, UInt32.self))
        guard length <= LiveGPUEnvelope.maxPayload, message.count == LiveGPUEnvelope.headerSize + length else { return nil }
        return Header(kind: number(6, UInt16.self), length: length,
                      executor: Data(message[(base + 16)..<(base + 32)]), generation: number(32, UInt64.self),
                      process: number(40, UInt64.self), stream: number(48, UInt64.self), sequence: number(56, UInt64.self))
    }

    static func isCompressedRecord(_ message: Data) -> Bool {
        message.count >= 4 && message.prefix(4).elementsEqual([0x43, 0x47, 0x4c, 0x5a])
    }

    static func payload(_ message: Data) -> Data { Data(message.dropFirst(LiveGPUEnvelope.headerSize)) }

    static func encode(kind: UInt16, executor: Data, generation: UInt64, payload: Data) -> Data {
        var result = Data([0x43, 0x47, 0x4c, 0x56])
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        append(UInt16(1)); append(kind); append(UInt32(payload.count)); append(UInt32(0))
        result.append(executor)
        append(generation); append(UInt64(0)); append(UInt64(0)); append(UInt64(0))
        result.append(payload)
        return result
    }

    static func ack(executor: Data, generation: UInt64, received: UInt64) -> Data {
        encode(kind: ack, executor: executor, generation: generation, payload: little(received))
    }

    static func resume(executor: Data, generation: UInt64, received: UInt64, nonce: Data) -> Data {
        encode(kind: resume, executor: executor, generation: generation, payload: little(received) + little(UInt64(0)) + nonce)
    }

    static func little(_ value: UInt64) -> Data {
        var little = value.littleEndian
        return withUnsafeBytes(of: &little) { Data($0) }
    }

    static func value(_ payload: Data) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(payload[payload.startIndex + $1]) << ($1 * 8) }
    }

    static func nonce() -> Data {
        while true {
            var bytes = [UInt8](repeating: 0, count: 16)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { continue }
            if bytes.contains(where: { $0 != 0 }) { return Data(bytes) }
        }
    }
}

/// One executor's transport across any number of WebSockets. When the session negotiated
/// resumption (the host issued a credential and the broker's first envelope is ACK), a lost
/// socket is replaced under the same executor: every sequenced envelope the phone sent stays
/// retained until the broker acknowledges it, the new socket opens with RESUME, and each side
/// retransmits what the other has not received. The session and its native executor never see
/// the gap. Without negotiation it behaves exactly as one socket.
final class LiveGPUResumableTransport: LiveGPUTransport, @unchecked Sendable {
    struct Policy {
        /// How long after a loss the phone keeps trying to resume before the executor ends.
        var holdWindow: TimeInterval = 30
        var retryInterval: TimeInterval = 0.25
        /// How long a new socket waits for the broker's RESUME before the next attempt.
        var resumeAnswer: TimeInterval = LiveGPUConnection.resumeTimeout
        var ackBytes = 64 * 1024
        var ackDelay: TimeInterval = 0.05
        /// Retained-envelope window. It leaves room for acknowledgements under the socket's
        /// own 8 MiB / 2048-message budget, so replay after a resume always fits it.
        var retainedBytes = LiveGPUBudget.byteLimit - 256 * 1024
        var retainedCount = LiveGPUBudget.countLimit - 64
    }
    enum Mode { case undecided, plain, resumable }
    private enum Link { case connecting, awaitingResume(Data), live, suspended, lost }

    private let connect: @Sendable (_ credential: String?) -> LiveGPUResumeSocket
    private let policy: Policy
    private let condition = NSCondition()
    private let timers = DispatchQueue(label: "caboose.gpu.resume")
    private var event: (@Sendable (LiveGPUTransportEvent) -> Void)?
    private var socket: LiveGPUResumeSocket?
    private var credential: String?
    private var mode = Mode.undecided
    private var link = Link.connecting
    private var started = false
    private var ended = false
    private var openedOnce = false
    private var identity: (executor: Data, generation: UInt64)?
    // Inbound: the highest contiguous sequence delivered upward, and acknowledgement pacing.
    private var received: UInt64 = 0
    private var acknowledged: UInt64 = 0
    private var unacknowledgedBytes = 0
    private var ackScheduled = false
    // Outbound: every sequenced envelope sent and not yet acknowledged, oldest first.
    private var retained: [(sequence: UInt64, data: Data)] = []
    private var retainedHead = 0
    private var retainedBytes = 0
    private var sentSequence: UInt64 = 0
    private var peerAcknowledged: UInt64 = 0
    private var lostAt: Date?
    private var attempts = 0

    var negotiatedMode: Mode { condition.withLock { mode } }
    private var resumeCount = 0
    /// Resumes after a loss, for diagnostics and tests.
    var resumes: Int { condition.withLock { resumeCount } }

    init(policy: Policy = Policy(), connect: @escaping @Sendable (_ credential: String?) -> LiveGPUResumeSocket) {
        self.policy = policy; self.connect = connect
    }

    convenience init(hostURL: URL, phoneToken: String) throws {
        let request = try LiveGPUConnection.makeRequest(hostURL: hostURL, phoneToken: phoneToken)
        self.init { credential in LiveGPUConnection(request: request, resumeCredential: credential) }
    }

    func open(_ event: @escaping @Sendable (LiveGPUTransportEvent) -> Void) {
        let socket: LiveGPUResumeSocket? = condition.withLock {
            guard !started, !ended else { return nil }
            started = true; self.event = event
            return openSocketLocked()
        }
        socket.map(attach)
    }

    func send(_ bytes: Data) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard !ended else { return false }
        guard mode == .resumable else {
            guard let socket else { return false }
            return socket.send(bytes)
        }
        guard let header = LiveGPUResumeWire.header(bytes), header.sequence == sentSequence + 1 else {
            // The binding hands over exactly one whole envelope per call, in sequence.
            failLocked(LiveGPUBindingError.protocolViolation("unsequenced output"))
            return false
        }
        while !ended && (retained.count - retainedHead >= policy.retainedCount ||
                         retainedBytes + bytes.count > policy.retainedBytes) {
            condition.wait()
        }
        guard !ended else { return false }
        retained.append((header.sequence, bytes)); retainedBytes += bytes.count
        sentSequence = header.sequence
        // A refused send ends that socket; the retained copy goes out after the resume.
        if case .live = link { _ = socket?.send(bytes) }
        return true
    }

    func close() {
        let socket = condition.withLock { () -> LiveGPUResumeSocket? in
            guard !ended else { return nil }
            ended = true; condition.broadcast()
            defer { self.socket = nil }
            return self.socket
        }
        socket?.close()
    }

    /// `suspendTransport` once every retained envelope is acknowledged, or after `timeout`.
    func suspendTransport(afterAcknowledgement timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            let waiting = condition.withLock { !ended && retainedHead < retained.count }
            if waiting && Date() < deadline {
                timers.asyncAfter(deadline: .now() + 0.05) { check() }
            } else {
                suspendTransport()
            }
        }
        check()
    }

    /// Ends the socket for the background with code 4001; the host holds the executor for its
    /// extended window. `resumeTransport` reconnects.
    func suspendTransport() {
        let socket = condition.withLock { () -> LiveGPUResumeSocket? in
            guard !ended, mode == .resumable else { return nil }
            Self.log("suspend close 4001")
            link = .suspended
            defer { self.socket = nil }
            return self.socket
        }
        socket?.closeSuspended()
    }

    /// Reconnects a suspended transport, or one still trying to resume, at once. A socket kept
    /// across the background that has heard nothing since is replaced rather than trusted.
    func resumeTransport() {
        let stale = condition.withLock { () -> LiveGPUResumeSocket? in
            guard !ended, mode == .resumable, case .live = link, let socket = self.socket, socket.silence > 2 else { return nil }
            return socket
        }
        if let stale {
            Self.log("resume replaces a silent socket silence=\(Int(stale.silence))")
            stale.close(abnormally: LiveGPUError.silent)
            return
        }
        let socket = condition.withLock { () -> LiveGPUResumeSocket? in
            guard !ended, mode == .resumable, self.socket == nil else { return nil }
            if case .suspended = link {} else if case .lost = link {} else { return nil }
            Self.log("resume requested link=\(link)")
            lostAt = Date(); attempts = 0
            return openSocketLocked()
        }
        socket.map(attach)
    }

    // MARK: Sockets

    /// One line per transport event on standard output, for device diagnostics.
    static func log(_ text: String) {
        print("CABOOSE_GPU_TRANSPORT \(text)")
        fflush(stdout)
    }

    private func openSocketLocked() -> LiveGPUResumeSocket {
        if mode == .resumable { Self.log("connect resume attempt=\(attempts) received=\(received) sent=\(sentSequence)") }
        let socket = connect(mode == .resumable ? credential : nil)
        self.socket = socket
        link = .connecting
        return socket
    }

    private func attach(_ socket: LiveGPUResumeSocket) {
        socket.open { [weak self, weak socket] incoming in
            guard let self, let socket else { return }
            self.receive(incoming, from: socket)
        }
    }

    private func receive(_ incoming: LiveGPUTransportEvent, from source: LiveGPUResumeSocket) {
        var deliveries: [LiveGPUTransportEvent] = []
        var reconnect: LiveGPUResumeSocket?
        condition.lock()
        guard !ended, source === socket else {
            condition.unlock()
            return
        }
        switch incoming {
        case .opened:
            if let credential = source.resumeCredential { self.credential = credential }
            Self.log("opened mode=\(mode) credential=\(source.resumeCredential != nil ? 1 : 0)")
            if mode == .resumable {
                // The splice is complete only when the broker answers this RESUME.
                let nonce = LiveGPUResumeWire.nonce()
                link = .awaitingResume(nonce)
                acknowledged = received; unacknowledgedBytes = 0
                if let identity {
                    _ = source.send(LiveGPUResumeWire.resume(executor: identity.executor, generation: identity.generation,
                                                             received: received, nonce: nonce))
                }
                // A computer that never answers (one that took the socket as a new executor)
                // gets the next attempt instead of this socket forever.
                timers.asyncAfter(deadline: .now() + policy.resumeAnswer) { [weak self, weak source] in
                    guard let self, let source else { return }
                    let stale = self.condition.withLock { () -> Bool in
                        guard source === self.socket, case .awaitingResume(let pending) = self.link else { return false }
                        return pending == nonce
                    }
                    if stale { source.close(abnormally: LiveGPUError.silent) }
                }
            } else {
                link = .live
            }
            if !openedOnce { openedOnce = true; deliveries.append(.opened) }
        case .bytes(let message):
            do { try inboundLocked(message, from: source, deliveries: &deliveries) }
            catch { failLocked(error); deliveries = []; condition.unlock(); finishUpward(error); return }
        case .closed(let error):
            socket = nil
            Self.log("closed mode=\(mode) link=\(link) error=\(error.map { String(describing: $0) } ?? "none")")
            if mode == .resumable, error != nil {
                if let refusal = error as? LiveGPUError, refusal == .resumeRefused {
                    ended = true; condition.broadcast()
                    deliveries.append(.closed(error))
                } else {
                    if lostAt == nil { lostAt = Date(); attempts = 0 }
                    link = .lost
                    if let lostAt, Date().timeIntervalSince(lostAt) < policy.holdWindow {
                        attempts += 1
                        if attempts == 1 {
                            reconnect = openSocketLocked()
                        } else {
                            scheduleRetryLocked()
                        }
                    } else {
                        ended = true; condition.broadcast()
                        deliveries.append(.closed(error))
                    }
                }
            } else {
                ended = true; condition.broadcast()
                deliveries.append(.closed(error))
            }
        }
        let event = self.event
        if ended { self.event = nil }
        condition.unlock()
        for delivery in deliveries { event?(delivery) }
        reconnect.map(attach)
    }

    private func scheduleRetryLocked() {
        timers.asyncAfter(deadline: .now() + policy.retryInterval) { [weak self] in
            guard let self else { return }
            let socket = self.condition.withLock { () -> LiveGPUResumeSocket? in
                guard !self.ended, self.socket == nil, case .lost = self.link else { return nil }
                return self.openSocketLocked()
            }
            socket.map(self.attach)
        }
    }

    private func inboundLocked(_ message: Data, from source: LiveGPUResumeSocket,
                               deliveries: inout [LiveGPUTransportEvent]) throws {
        func violation(_ text: String) -> Error { LiveGPUBindingError.protocolViolation(text) }
        switch mode {
        case .plain:
            deliveries.append(.bytes(message)); return
        case .undecided:
            // Resumption needs both the host's credential and the broker's leading ACK.
            if credential != nil, let header = LiveGPUResumeWire.header(message), header.kind == LiveGPUResumeWire.ack,
               header.length == LiveGPUResumeWire.ackPayload, header.sequence == 0, header.process == 0, header.stream == 0,
               header.executor.contains(where: { $0 != 0 }), header.generation > 0,
               LiveGPUResumeWire.value(LiveGPUResumeWire.payload(message)) == 0 {
                mode = .resumable
                identity = (header.executor, header.generation)
                Self.log("resumable")
                return
            }
            mode = .plain
            Self.log("plain credential=\(credential != nil ? 1 : 0)")
            deliveries.append(.bytes(message)); return
        case .resumable: break
        }
        guard let identity else { throw violation("resume identity") }
        if LiveGPUResumeWire.isCompressedRecord(message) {
            // A record carries exactly one DATA envelope; the decoder checks its sequence.
            guard case .live = link else { return }
            try deliverLocked(message, deliveries: &deliveries)
            return
        }
        guard let header = LiveGPUResumeWire.header(message) else {
            if case .awaitingResume = link { return }
            throw violation("resumable message is not one envelope")
        }
        if case .awaitingResume(let nonce) = link {
            // Everything the relay queued before the splice is retransmitted after this RESUME.
            guard header.kind == LiveGPUResumeWire.resume, header.length == LiveGPUResumeWire.resumePayload,
                  header.sequence == 0, header.executor == identity.executor, header.generation == identity.generation,
                  LiveGPUResumeWire.payload(message).suffix(16) == nonce else { return }
            let payload = LiveGPUResumeWire.payload(message)
            guard LiveGPUResumeWire.value(payload.subdata(in: payload.startIndex.advanced(by: 8)..<payload.startIndex.advanced(by: 16))) == 0 else {
                throw violation("RESUME reserved field")
            }
            try acknowledgeLocked(LiveGPUResumeWire.value(payload))
            link = .live; lostAt = nil; attempts = 0; resumeCount += 1
            replayLocked(to: source)
            print("CABOOSE_GPU_RESUMED received=\(received) sent=\(sentSequence) replayed=\(retained.count - retainedHead)")
            return
        }
        guard header.executor == identity.executor, header.generation == identity.generation else {
            throw violation("identity mismatch")
        }
        switch header.kind {
        case LiveGPUResumeWire.ack:
            guard header.length == LiveGPUResumeWire.ackPayload, header.sequence == 0, header.process == 0, header.stream == 0 else {
                throw violation("invalid ACK")
            }
            try acknowledgeLocked(LiveGPUResumeWire.value(LiveGPUResumeWire.payload(message)))
        case LiveGPUResumeWire.resume:
            throw violation("unexpected RESUME")
        default:
            guard header.sequence == received + 1 else { throw violation("sequence gap after resume") }
            try deliverLocked(message, deliveries: &deliveries)
        }
    }

    private func deliverLocked(_ message: Data, deliveries: inout [LiveGPUTransportEvent]) throws {
        guard received < UInt64.max else { throw LiveGPUBindingError.protocolViolation("sequence exhausted") }
        received += 1
        unacknowledgedBytes += message.count
        deliveries.append(.bytes(message))
        if unacknowledgedBytes >= policy.ackBytes { sendAckLocked() }
        else if !ackScheduled {
            ackScheduled = true
            timers.asyncAfter(deadline: .now() + policy.ackDelay) { [weak self] in
                guard let self else { return }
                self.condition.withLock { self.ackScheduled = false; self.sendAckLocked() }
            }
        }
    }

    private func sendAckLocked() {
        guard !ended, case .live = link, let socket, let identity, received > acknowledged else { return }
        // A stalled socket keeps at most a few acknowledgements queued; each covers the last.
        guard socket.queuedMessages < 16 else { return }
        if socket.send(LiveGPUResumeWire.ack(executor: identity.executor, generation: identity.generation, received: received)) {
            acknowledged = received; unacknowledgedBytes = 0
        }
    }

    private func acknowledgeLocked(_ value: UInt64) throws {
        guard value >= peerAcknowledged, value <= sentSequence else {
            throw LiveGPUBindingError.protocolViolation("acknowledgement out of range")
        }
        peerAcknowledged = value
        var released = false
        while retainedHead < retained.count, retained[retainedHead].sequence <= value {
            retainedBytes -= retained[retainedHead].data.count
            retainedHead += 1; released = true
        }
        if retainedHead > 256, retainedHead * 2 > retained.count {
            retained.removeFirst(retainedHead); retainedHead = 0
        }
        if released { condition.broadcast() }
    }

    /// Sends every retained envelope after the broker's RESUME value, coalesced into whole
    /// envelope runs of at most one WebSocket message.
    private func replayLocked(to socket: LiveGPUResumeSocket) {
        var batch = Data()
        for index in retainedHead..<retained.count {
            let data = retained[index].data
            if !batch.isEmpty && batch.count + data.count > LiveGPUBudget.messageLimit {
                _ = socket.send(batch); batch = Data()
            }
            batch.append(data)
        }
        if !batch.isEmpty { _ = socket.send(batch) }
    }

    private func failLocked(_ error: Error) {
        guard !ended else { return }
        Self.log("failed error=\(error)")
        ended = true; condition.broadcast()
        let socket = self.socket
        self.socket = nil
        socket?.close()
    }

    private func finishUpward(_ error: Error) {
        let event = condition.withLock { () -> (@Sendable (LiveGPUTransportEvent) -> Void)? in
            defer { self.event = nil }
            return self.event
        }
        event?(.closed(error))
    }
}
