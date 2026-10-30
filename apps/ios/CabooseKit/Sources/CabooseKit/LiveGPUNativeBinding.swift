import Foundation
import Darwin
#if canImport(CabooseGPULive)
import CabooseGPULive
#endif

public enum LiveGPUBindingError: Error, Equatable, Sendable {
    case native(operation: String, code: Int32)
    case system(operation: String, code: Int32)
    case protocolViolation(String)
    case outputRejected
}

/// Injectable only at the byte/runtime boundary. Production always uses the linked C API.
protocol LiveGPURuntimeBackend: Sendable {
    func start() -> Int32
    func open(_ token: inout UInt64) -> Int32
    func run(_ token: UInt64, fd: Int32, maxPacket: Int, maxReply: Int) -> Int32
    func stop(_ token: UInt64) -> Int32
    func finish(_ token: UInt64) -> Int32
}

private struct LinkedLiveGPURuntime: LiveGPURuntimeBackend {
    // Swift's static initialization serializes even simultaneous session starts. A failed
    // initialization remains failed for process lifetime; reconnect never retries it.
    private static let startResult: Int32 = {
        #if canImport(CabooseGPULive)
        return caboose_gpu_live_start_v3()
        #else
        return ENODEV
        #endif
    }()
    func start() -> Int32 { Self.startResult }
    func open(_ token: inout UInt64) -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_open(&token)
        #else
        return ENODEV
        #endif
    }
    func run(_ token: UInt64, fd: Int32, maxPacket: Int, maxReply: Int) -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_run(token, fd, maxPacket, maxReply)
        #else
        return ENODEV
        #endif
    }
    func stop(_ token: UInt64) -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_stop(token)
        #else
        return ENODEV
        #endif
    }
    func finish(_ token: UInt64) -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_finish(token)
        #else
        return ENODEV
        #endif
    }
}

/// Descriptors remain owned until both workers have joined. shutdown is safe against
/// concurrent IO; close is deliberately deferred so descriptor reuse cannot race a run.
private final class LiveGPUDuplex: @unchecked Sendable {
    let bridge: Int32
    let native: Int32
    let workers = DispatchGroup()
    var inboundFinished = false // consumer worker only
    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw LiveGPUBindingError.system(operation: "socketpair", code: errno)
        }
        bridge = descriptors[0]; native = descriptors[1]
        for fd in descriptors {
            var one: Int32 = 1
            var size: Int32 = 16 * 1024
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                let code = errno
                Darwin.close(bridge); Darwin.close(native)
                throw LiveGPUBindingError.system(operation: "socket configuration", code: code)
            }
        }
    }
    func cancel() { shutdown(bridge, SHUT_RDWR); shutdown(native, SHUT_RDWR) }
    func closeAfterJoin() { workers.wait(); Darwin.close(bridge); Darwin.close(native) }
    func write(_ bytes: Data) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(bridge, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw LiveGPUBindingError.system(operation: "write", code: count == 0 ? EPIPE : errno) }
                offset += count
            }
        }
    }
}

private final class LiveGPUProcess: @unchecked Sendable {
    let token: UInt64
    let lock = NSLock()
    var streams: [UInt64: LiveGPUDuplex] = [:]
    var stopped = false
    var cleanupError: Error?
    init(_ token: UInt64) { self.token = token }
    func stop(_ backend: LiveGPURuntimeBackend) {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            for stream in streams.values { stream.cancel() }
            let result = backend.stop(token)
            if result != 0 { cleanupError = LiveGPUBindingError.native(operation: "stop", code: result) }
        }
    }
}

/// One authenticated CGLV lease. start/consume/finish are serial worker calls;
/// revoke may run concurrently, including before start. No presentation claim is made.
public final class LiveGPUNativeBinding: LiveGPUByteConsumer, @unchecked Sendable {
    private let backend: LiveGPURuntimeBackend
    private let decoder: LiveGPUEnvelopeDecoder
    private let maxPacket: Int
    private let maxReply: Int
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var cancelled = false
    private var started = false
    private var finished = false
    private var negotiated = false
    private var drainRequested = false
    private var drainSent = false
    private var peerRevoked = false
    private var identity: (Data, UInt64)?
    private var processes: [UInt64: LiveGPUProcess] = [:]
    private var lastProcess: UInt64 = 0
    private var lastStream: UInt64 = 0
    private var outputSequence: UInt64 = 1
    private var outputExhausted = false
    private var output: (@Sendable (Data) -> Bool)?
    private var failed: (@Sendable (Error) -> Void)?
    private var failure: Error?
    private var finishError: Error?
    private var retirementError: Error?
    private var decodingFailed = false

    public convenience init(maxPacket: Int = 16 * 1024 * 1024, maxReplyBuffer: Int = 1024 * 1024) throws {
        #if canImport(CabooseGPULive)
        try self.init(backend: LinkedLiveGPURuntime(), maxPacket: maxPacket, maxReplyBuffer: maxReplyBuffer)
        #else
        throw LiveGPUError.missingNativeBinding
        #endif
    }
    init(backend: LiveGPURuntimeBackend, maxPacket: Int = 16 * 1024 * 1024,
         maxReplyBuffer: Int = 1024 * 1024, executor: Data? = nil, generation: UInt64? = nil) throws {
        guard (8...400 * 1024 * 1024).contains(maxPacket), (4096...1024 * 1024).contains(maxReplyBuffer) else {
            throw LiveGPUBindingError.protocolViolation("invalid native buffer limits")
        }
        self.backend = backend; self.maxPacket = maxPacket; maxReply = maxReplyBuffer
        decoder = try LiveGPUEnvelopeDecoder(executor: executor, generation: generation)
    }
    public func start(output: @escaping @Sendable (Data) -> Bool,
                      failed: @escaping @Sendable (Error) -> Void) throws {
        try lock.withLock {
            guard !started, !cancelled else { throw LiveGPUError.closed }
            started = true; self.output = output; self.failed = failed
        }
        // Initialization is deliberately postponed until the exact SESSION hello arrives.
    }
    public func consume(_ bytes: Data) throws {
        guard lock.withLock({ started && !cancelled && !finished && !peerRevoked }) else { throw LiveGPUError.closed }
        do { try decoder.feed(bytes) { try handle($0) } }
        catch { decodingFailed = true; fail(error); throw error }
    }
    /// Serial consumer-worker operation. A close before SESSION is retained until
    /// negotiation; no native work or socket is discarded to manufacture retirement.
    public func requestDrain() throws {
        guard lock.withLock({ started && !cancelled && !finished }) else { throw LiveGPUError.closed }
        drainRequested = true
        try sendDrainIfReady()
    }
    private func sendDrainIfReady() throws {
        guard negotiated, drainRequested, !drainSent, !peerRevoked else { return }
        try send(.executorDrain)
        drainSent = true
    }
    private func send(_ kind: LiveGPUEnvelope.Kind, process: UInt64 = 0, stream: UInt64 = 0, payload: Data = Data()) throws {
        try outputLock.withLock {
            let callback = try lock.withLock { () throws -> (@Sendable (Data) -> Bool) in
                guard !cancelled, let output else { throw LiveGPUError.closed }
                return output
            }
            guard let identity, !outputExhausted else { throw LiveGPUBindingError.protocolViolation("output identity or sequence exhausted") }
            let wire = try LiveGPUEnvelope(kind: kind, executor: identity.0, generation: identity.1,
                process: process, stream: stream, sequence: outputSequence, payload: payload).encoded()
            guard callback(wire) else { throw LiveGPUBindingError.outputRejected }
            if outputSequence == UInt64.max { outputExhausted = true } else { outputSequence += 1 }
        }
    }
    private func handle(_ frame: LiveGPUEnvelope) throws {
        guard !peerRevoked, !lock.withLock({ cancelled }) else { throw LiveGPUError.closed }
        if !negotiated {
            guard frame.kind == .session, frame.payload == LiveGPUEnvelope.hello else {
                throw LiveGPUBindingError.protocolViolation("unsupported SESSION hello")
            }
            let result = backend.start()
            guard result == 0 else { throw LiveGPUBindingError.native(operation: "start", code: result) }
            identity = (frame.executor, frame.generation); negotiated = true
            try send(.sessionReady, payload: LiveGPUEnvelope.hello)
            try sendDrainIfReady()
            return
        }
        switch frame.kind {
        case .processOpen:
            guard frame.process > lastProcess, lock.withLock({ processes.count < 16 }) else {
                throw LiveGPUBindingError.protocolViolation("process identity or capacity")
            }
            var token: UInt64 = 0
            let result = backend.open(&token)
            guard result == 0 else { throw LiveGPUBindingError.native(operation: "open", code: result) }
            guard token > 0 else { throw LiveGPUBindingError.protocolViolation("native open returned zero token") }
            let process = LiveGPUProcess(token)
            let revoked = lock.withLock { processes[frame.process] = process; return cancelled }
            if revoked { process.stop(backend); throw LiveGPUError.closed }
            lastProcess = frame.process
            try send(.processReady, process: frame.process)
        case .streamOpen:
            try openStream(frame)
        case .data, .fin:
            let process = try process(frame.process)
            guard let stream = process.lock.withLock({ process.streams[frame.stream] }), !stream.inboundFinished else {
                throw LiveGPUBindingError.protocolViolation("unknown or half-closed stream")
            }
            if frame.kind == .data { try stream.write(frame.payload) }
            else {
                stream.inboundFinished = true
                guard shutdown(stream.bridge, SHUT_WR) == 0 else { throw LiveGPUBindingError.system(operation: "half-close", code: errno) }
            }
        case .processStop:
            let process = try process(frame.process)
            try retire(frame.process, process)
            try send(.processRetired, process: frame.process)
        case .revoke:
            peerRevoked = true
            let snapshot = lock.withLock { processes }
            for process in snapshot.values { process.stop(backend) }
            for (id, process) in snapshot.sorted(by: { $0.key < $1.key }) {
                try retire(id, process)
                try send(.processRetired, process: id)
            }
            try send(.revoked)
        default: throw LiveGPUBindingError.protocolViolation("unexpected peer message")
        }
    }
    private func process(_ id: UInt64) throws -> LiveGPUProcess {
        guard let process = lock.withLock({ processes[id] }) else { throw LiveGPUBindingError.protocolViolation("unknown process") }
        return process
    }
    private func openStream(_ frame: LiveGPUEnvelope) throws {
        let process = try process(frame.process)
        // Reclaim only streams with both FIN directions and both workers returned.
        let snapshot = lock.withLock { Array(processes.values) }
        for p in snapshot {
            p.lock.withLock {
                for (id, stream) in p.streams where stream.inboundFinished && stream.workers.wait(timeout: .now()) == .success {
                    stream.closeAfterJoin(); p.streams.removeValue(forKey: id)
                }
            }
        }
        let count = snapshot.reduce(0) { total, p in total + p.lock.withLock { p.streams.count } }
        guard frame.stream > lastStream, count < 64 else { throw LiveGPUBindingError.protocolViolation("stream identity or capacity") }
        let stream = try LiveGPUDuplex()
        // Reserve both workers before publishing the descriptors to concurrent revoke.
        stream.workers.enter(); stream.workers.enter()
        process.lock.withLock {
            process.streams[frame.stream] = stream
            if process.stopped { stream.cancel() }
        }
        lastStream = frame.stream
        let gate = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            defer { stream.workers.leave() }
            gate.wait()
            let result = backend.run(process.token, fd: stream.native, maxPacket: maxPacket, maxReply: maxReply)
            // Native does not own the fd. Its write half ends only after run returns.
            shutdown(stream.native, SHUT_WR)
            if result != 0 && !(result == ECANCELED && process.lock.withLock({ process.stopped })) {
                fail(LiveGPUBindingError.native(operation: "run", code: result))
            }
        }
        Thread.detachNewThread { [self] in
            defer { stream.workers.leave() }
            gate.wait()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.read(stream.bridge, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                if process.lock.withLock({ process.stopped }) { return }
                do {
                    if count < 0 { throw LiveGPUBindingError.system(operation: "read", code: errno) }
                    if count == 0 { try send(.fin, process: frame.process, stream: frame.stream); return }
                    try send(.data, process: frame.process, stream: frame.stream, payload: Data(buffer.prefix(count)))
                } catch { fail(error); return }
            }
        }
        // STREAM_READY reserves the bounded socketpair and both workers for an
        // already-open native token. It is not a TLS-admission or GPU receipt.
        // The frozen CGLV contract permits run to fail after this reservation.
        defer { gate.signal(); gate.signal() }
        try send(.streamReady, process: frame.process, stream: frame.stream)
    }
    private func retire(_ id: UInt64, _ process: LiveGPUProcess) throws {
        process.stop(backend)
        let streams = process.lock.withLock { Array(process.streams.values) }
        for stream in streams { stream.workers.wait() }
        process.lock.withLock {
            for stream in process.streams.values { stream.closeAfterJoin() }
            process.streams.removeAll()
        }
        let result = backend.finish(process.token)
        lock.withLock { _ = processes.removeValue(forKey: id) }
        if result != 0 {
            let error = LiveGPUBindingError.native(operation: "finish", code: result)
            retirementError = error; throw error
        }
        if let error = process.lock.withLock({ process.cleanupError }) { retirementError = error; throw error }
    }
    private func fail(_ error: Error) {
        let callback = lock.withLock { () -> (@Sendable (Error) -> Void)? in
            guard failure == nil else { return nil }
            failure = error; return failed
        }
        try? revoke()
        callback?(error)
    }
    public func revoke() throws {
        let snapshot = lock.withLock { cancelled = true; return Array(processes.values) }
        for process in snapshot { process.stop(backend) }
        if let error = snapshot.compactMap({ p in p.lock.withLock { p.cleanupError } }).first { throw error }
    }
    public func finish() throws {
        if finished { if let finishError { throw finishError }; return }
        var error: Error? = retirementError
        do { try revoke() } catch let caught { error = caught }
        let snapshot = lock.withLock { processes }
        for (id, process) in snapshot {
            do { try retire(id, process) } catch let caught { if error == nil { error = caught } }
        }
        if !decodingFailed {
            do { try decoder.finish() } catch let caught { if error == nil { error = caught } }
        }
        lock.withLock { finished = true; output = nil; failed = nil }
        finishError = error
        if let error { throw error }
    }
}
