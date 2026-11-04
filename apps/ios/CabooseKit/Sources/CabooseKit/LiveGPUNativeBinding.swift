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
    /// Selects the connected computer's persistent caches; nil keeps none.
    func setCacheRoot(_ path: String?) -> Int32
    func open(_ token: inout UInt64) -> Int32
    func run(_ token: UInt64, fd: Int32, maxPacket: Int, maxReply: Int) -> Int32
    func stop(_ token: UInt64) -> Int32
    func finish(_ token: UInt64) -> Int32
    /// Stops all decoding at command boundaries and waits every queue idle; ETIMEDOUT leaves
    /// it stopping. ENOTSUP when the runtime cannot suspend.
    func suspend(timeoutMilliseconds: UInt32) -> Int32
    func resume() -> Int32
    /// Prints the native teardown report (caboose_gpu_runtime_report_teardown).
    func reportTeardown()
    /// The executor's counters (caboose_gpu_runtime_executor_stats), or nil.
    func executorStats() -> LiveGPUExecutorStats?
}

extension LiveGPURuntimeBackend {
    func suspend(timeoutMilliseconds: UInt32) -> Int32 { ENOTSUP }
    func resume() -> Int32 { ENOTSUP }
    func reportTeardown() {}
    func executorStats() -> LiveGPUExecutorStats? { nil }
}

/// Suspend in place (docs/gpu-live.md, "Suspending an executor"). Serial worker calls.
protocol LiveGPUSuspending: AnyObject {
    /// Stops native decoding, sends EXECUTOR_SUSPEND and holds every later process message
    /// until resume. `quiesced` runs once QUIESCED has been sent. False when this executor
    /// cannot suspend; it is then unchanged.
    func suspend(quiesced: @escaping @Sendable () -> Void) throws -> Bool
    /// Continues decoding and the held messages, and sends EXECUTOR_RESUME once the broker's
    /// QUIESCE has been answered.
    func resumeExecutor() throws
}

private struct LinkedLiveGPURuntime: LiveGPURuntimeBackend {
    // Swift's static initialization serializes even simultaneous session starts. A failed
    // initialization remains failed for process lifetime; reconnect never retries it.
    private static let startResult: Int32 = {
        #if canImport(CabooseGPULive)
        #if DEBUG
        if ProcessInfo.processInfo.environment["CABOOSE_PRIVATE_GPU_MEMORY_AUDIT"] == "1" {
            #if canImport(CabooseGPUMemoryAudit)
            let audit = LiveGPUMemoryAudit.enable()
            if audit != 0 { return audit }
            #else
            return ENOTSUP
            #endif
        }
        #endif
        let result = caboose_gpu_live_start_v4()
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        if result == 0 { LiveGPUMemoryAudit.features() }
        #endif
        return result
        #else
        return ENODEV
        #endif
    }()
    func start() -> Int32 { Self.startResult }
    func setCacheRoot(_ path: String?) -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_set_cache_root(path)
        #else
        return ENODEV
        #endif
    }
    func open(_ token: inout UInt64) -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_open(&token)
        #else
        return ENODEV
        #endif
    }
    func run(_ token: UInt64, fd: Int32, maxPacket: Int, maxReply: Int) -> Int32 {
        #if canImport(CabooseGPULive)
        let result = caboose_gpu_runtime_run(token, fd, maxPacket, maxReply)
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.runResult(token: token, code: result)
        #endif
        return result
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
    func reportTeardown() {
        #if canImport(CabooseGPULive)
        caboose_gpu_runtime_report_teardown()
        #endif
    }
    func executorStats() -> LiveGPUExecutorStats? {
        #if canImport(CabooseGPULive)
        var raw = caboose_gpu_executor_stats()
        raw.size = UInt64(MemoryLayout<caboose_gpu_executor_stats>.size)
        guard caboose_gpu_runtime_executor_stats(&raw) == 0 else { return nil }
        return LiveGPUExecutorStats(commands: raw.commands, decodeMicroseconds: raw.decode_us,
            readBytes: raw.read_bytes, readWaitMicroseconds: raw.read_wait_us, flushMicroseconds: raw.flush_us,
            submitted: raw.submitted, completed: raw.completed, completionMicroseconds: raw.completion_us,
            gpuBusyMicroseconds: raw.gpu_busy_us, outstanding: raw.outstanding, outstandingMax: raw.outstanding_max)
        #else
        return nil
        #endif
    }
    func suspend(timeoutMilliseconds: UInt32) -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_suspend(timeoutMilliseconds)
        #else
        return ENODEV
        #endif
    }
    func resume() -> Int32 {
        #if canImport(CabooseGPULive)
        return caboose_gpu_runtime_resume()
        #else
        return ENODEV
        #endif
    }
    func finish(_ token: UInt64) -> Int32 {
        #if canImport(CabooseGPULive)
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        // Snapshot while the native process identity still exists, after its
        // streams have joined. Diagnostic failure never skips actual cleanup.
        LiveGPUMemoryAudit.receipts(token)
        #endif
        return caboose_gpu_runtime_finish(token)
        #else
        return ENODEV
        #endif
    }
}

/// Descriptors remain owned until both workers have joined. shutdown is safe against
/// concurrent IO; close is deliberately deferred so descriptor reuse cannot race a run.
private final class LiveGPUDuplex: @unchecked Sendable {
    private static let installWakeSignal: Void = {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        sigemptyset(&action.sa_mask)
        action.sa_flags = SA_RESTART
        _ = sigaction(SIGUSR1, &action, nil)
    }()
    let bridge: Int32
    let native: Int32
    let workers = DispatchGroup()
    var inboundFinished = false // guarded by owning LiveGPUProcess.lock
    private let stateLock = NSLock()
    private var nativeReaderThread: pthread_t?
    private var bridgeWriteClosed = false
    private var replyingNow = false
    /// The reply reader holds bytes it read and has not yet handed to the transport.
    var replying: Bool {
        get { stateLock.withLock { replyingNow } }
        set { stateLock.withLock { replyingNow = newValue } }
    }
    /// Reply bytes the native decoder wrote that the reader has not read yet.
    var unreadReplies: Int32 {
        var count: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(bridge, SOL_SOCKET, SO_NREAD, &count, &size) == 0 ? count : 1
    }
    /// Native run returned with an error: this stream alone ends, and further input for it
    /// is discarded. Guarded by the owning LiveGPUProcess.lock.
    var nativeEnded = false
    init() throws {
        _ = Self.installWakeSignal
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw LiveGPUBindingError.system(operation: "socketpair", code: errno)
        }
        bridge = descriptors[0]; native = descriptors[1]
        for fd in descriptors {
            var one: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one))) == 0,
                  fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                let code = errno
                Darwin.close(bridge); Darwin.close(native)
                throw LiveGPUBindingError.system(operation: "socket configuration", code: code)
            }
        }
        // Commands to the decoder get a deep buffer, so a decoder that is briefly busy (a
        // pipeline compile, a wait) never stalls its writer; replies a smaller one. The
        // largest size the kernel takes, from these down.
        guard Self.setBuffer(bridge, SO_SNDBUF, Self.commandBuffer), Self.setBuffer(native, SO_RCVBUF, Self.commandBuffer),
              Self.setBuffer(native, SO_SNDBUF, Self.replyBuffer), Self.setBuffer(bridge, SO_RCVBUF, Self.replyBuffer),
              // The bridge never blocks: its writer and reader poll, and see a stop between polls.
              fcntl(bridge, F_SETFL, fcntl(bridge, F_GETFL) | O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(bridge); Darwin.close(native)
            throw LiveGPUBindingError.system(operation: "socket configuration", code: code)
        }
    }
    static let commandBuffer: Int32 = 1024 * 1024
    static let replyBuffer: Int32 = 256 * 1024
    private static func setBuffer(_ fd: Int32, _ option: Int32, _ preferred: Int32) -> Bool {
        var size = preferred
        while size >= 16 * 1024 {
            if setsockopt(fd, SOL_SOCKET, option, &size, socklen_t(MemoryLayout.size(ofValue: size))) == 0 { return true }
            guard errno == ENOBUFS || errno == EINVAL else { return false }
            size /= 2
        }
        return false
    }
    /// The socket's buffer size as the kernel set it.
    func bufferSize(_ fd: Int32, _ option: Int32) -> Int32 {
        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, option, &value, &size) == 0 ? value : -1
    }
    func beginNativeRun() {
        stateLock.withLock { nativeReaderThread = pthread_self() }
    }
    func endNativeRun() {
        stateLock.withLock { nativeReaderThread = nil }
    }
    func halfCloseBridgeWrite() throws {
        try stateLock.withLock {
            guard shutdown(bridge, SHUT_WR) == 0 else {
                throw LiveGPUBindingError.system(operation: "half-close", code: errno)
            }
            bridgeWriteClosed = true
        }
    }
    /// On XNU AF_UNIX SOCK_STREAM, shutdown(bridge, SHUT_WR) calls socantrcvmore(native)
    /// without holding native's socket mutex. If native's reader enters sbwait in that
    /// window, sowakeup clears SB_WAIT before msleep joins the waitqueue. A thread-directed
    /// SA_RESTART signal wakes msleep so soreceive re-checks SS_CANTRCVMORE and returns EOF.
    func nudgeNativeReaderIfDisconnected() {
        stateLock.withLock {
            guard bridgeWriteClosed, let thread = nativeReaderThread else { return }
            var pfd = pollfd(fd: native, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&pfd, 1, 0) > 0 && (pfd.revents & Int16(POLLHUP)) != 0 {
                _ = pthread_kill(thread, SIGUSR1)
            }
        }
    }
    func cancel() {
        stateLock.withLock {
            bridgeWriteClosed = true
            // Shut down each direction separately: on XNU AF_UNIX SOCK_STREAM,
            // shutdown(fd, SHUT_RDWR) returns ENOTCONN before shutting down SHUT_WR
            // whenever SS_CANTRCVMORE is already set on fd.
            _ = shutdown(bridge, SHUT_RD)
            _ = shutdown(bridge, SHUT_WR)
            _ = shutdown(native, SHUT_RD)
            _ = shutdown(native, SHUT_WR)
            if let thread = nativeReaderThread {
                _ = pthread_kill(thread, SIGUSR1)
            }
        }
        cancelWriter()
    }
    func waitForWorkers() {
        while workers.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
            nudgeNativeReaderIfDisconnected()
        }
    }
    /// True once both workers have returned, false at `deadline` (they are still owed).
    func waitForWorkers(until deadline: DispatchTime) -> Bool {
        while workers.wait(timeout: .now() + .milliseconds(2)) == .timedOut {
            if DispatchTime.now() >= deadline { return false }
            nudgeNativeReaderIfDisconnected()
        }
        return true
    }
    func closeAfterJoin() { waitForWorkers(); Darwin.close(bridge); Darwin.close(native) }

    // Inbound commands wait here for this stream's own writer, so a decoder that is busy or
    // blocked holds back only its own stream, never the serial consumer or another stream.
    // Each payload keeps its ingress charge until it is in the socket (LiveGPUIngressHold),
    // so the session's ingress budget still bounds every byte waiting here.
    private enum Inbound { case data(Data, LiveGPUIngressHold?), fin }
    private let inbound = NSCondition()
    private var inboundQueue: [Inbound] = []
    private var inboundHead = 0
    private var writerCancelled = false
    private var writerGone = false
    /// Queues bytes for the decoder; false once the writer has ended (they are dropped).
    @discardableResult
    func enqueue(_ bytes: Data, hold: LiveGPUIngressHold?) -> Bool {
        inbound.lock()
        guard !writerGone, !writerCancelled else { inbound.unlock(); return false }
        hold?.retain()
        inboundQueue.append(.data(bytes, hold))
        inbound.signal()
        inbound.unlock()
        return true
    }
    /// The decoder's input ends after everything queued before it.
    func enqueueFin() {
        inbound.withLock {
            guard !writerGone, !writerCancelled else { return }
            inboundQueue.append(.fin)
            inbound.signal()
        }
    }
    /// Bytes queued for the decoder and not yet in its socket.
    var queuedInbound: Int {
        inbound.withLock {
            inboundQueue[inboundHead...].reduce(0) { total, item in
                if case .data(let bytes, _) = item { return total + bytes.count }
                return total
            }
        }
    }
    private func cancelWriter() {
        inbound.withLock { writerCancelled = true; inbound.broadcast() }
    }
    /// The writer worker: writes queued commands in order until FIN, cancel or a failure.
    /// `discard` says the decoder has ended (its bytes are dropped); `failed` reports a
    /// write failure that is not a stop.
    func runWriter(discard: () -> Bool, failed: (Error) -> Void) {
        defer {
            let dropped = inbound.withLock { () -> ArraySlice<Inbound> in
                writerGone = true
                defer { inboundQueue = []; inboundHead = 0 }
                return inboundQueue[inboundHead...]
            }
            for case .data(_, let hold) in dropped { hold?.release() }
        }
        while true {
            inbound.lock()
            while inboundHead == inboundQueue.count && !writerCancelled { inbound.wait() }
            if writerCancelled { inbound.unlock(); return }
            let item = inboundQueue[inboundHead]
            inboundQueue[inboundHead] = .fin  // drop the payload reference
            inboundHead += 1
            if inboundHead == inboundQueue.count { inboundQueue.removeAll(keepingCapacity: true); inboundHead = 0 }
            else if inboundHead >= 1024 { inboundQueue.removeFirst(inboundHead); inboundHead = 0 }
            inbound.unlock()
            switch item {
            case .data(let bytes, let hold):
                defer { hold?.release() }
                if discard() { continue }
                do { try write(bytes, stop: { [self] in discard() || inbound.withLock { writerCancelled } }) }
                catch {
                    if discard() || inbound.withLock({ writerCancelled }) { continue }
                    failed(error); return
                }
            case .fin:
                do { try halfCloseBridgeWrite() } catch { failed(error) }
                return
            }
        }
    }
    /// Writes all of `bytes` to the non-blocking bridge, waiting for room between writes;
    /// returns early once `stop` holds.
    private func write(_ bytes: Data, stop: () -> Bool) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(bridge, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && errno == EAGAIN {
                    if stop() { return }
                    var pfd = pollfd(fd: bridge, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&pfd, 1, 50)
                    continue
                }
                throw LiveGPUBindingError.system(operation: "write", code: count == 0 ? EPIPE : errno)
            }
        }
    }
}

/// One ingress charge (a transport message) held until every payload decoded from it is
/// in its stream's socket or dropped; `release` then runs once.
final class LiveGPUIngressHold: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 1
    private var done: (() -> Void)?
    init(_ done: @escaping () -> Void) { self.done = done }
    func retain() { lock.withLock { count += 1 } }
    func release() {
        let callback = lock.withLock { () -> (() -> Void)? in
            count -= 1
            guard count == 0 else { return nil }
            defer { done = nil }
            return done
        }
        callback?()
    }
}

private final class LiveGPUProcess: @unchecked Sendable {
    let token: UInt64
    let lock = NSLock()
    var streams: [UInt64: LiveGPUDuplex] = [:]
    var stopped = false
    var cleanupError: Error?
    /// Where its retirement stands, for the teardown report (under `lock`).
    var teardownStep = "running"
    var teardownSince = Date()
    func enter(_ step: String) { lock.withLock { teardownStep = step; teardownSince = Date() } }
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
public final class LiveGPUNativeBinding: LiveGPUByteConsumer, LiveGPURetirementReporting, LiveGPUSurfaceRevoking, LiveGPUIngressAccounting, LiveGPUDeferredIngress, LiveGPUSuspending, LiveGPUTeardownReporting, @unchecked Sendable {
    private let backend: LiveGPURuntimeBackend
    private let decoder: LiveGPUEnvelopeDecoder
    private let surfaces: LiveGPUSurfaceController?
    private let maxPacket: Int
    private let maxReply: Int
    private let cacheRoot: URL?
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var cancelled = false
    private var started = false
    private var finished = false
    private var negotiated = false
    private var compression: LiveGPUCompression.Algorithm? // guarded by lock for network admission
    private var compressedTransport: Bool { compression != nil }
    private var zstd: LiveGPUZstdStream? // worker only: the session's one zstd stream
    /// The zstd window this phone takes, from the memory iOS still allows the app.
    var zstdWindowLog: () -> UInt32 = {
        #if os(iOS)
        LiveGPUCompression.preferredWindowLog(available: os_proc_available_memory())
        #else
        26
        #endif
    }
    private var drainRequested = false
    private var drainSent = false
    private var peerRevoked = false
    private var receiptSent = false
    var retirementReceiptSent: Bool { lock.withLock { receiptSent } }
    private var identity: (Data, UInt64)?
    private var processes: [UInt64: LiveGPUProcess] = [:]
    private var lastProcess: UInt64 = 0
    private var lastStream: UInt64 = 0
    // Every identity this generation has opened. The broker never reuses one, but may send
    // the openings of two local clients out of order, so a lower new identity is accepted.
    private var openedProcesses = Set<UInt64>()
    private var openedStreams = Set<UInt64>()
    private var outputSequence: UInt64 = 1
    private var outputExhausted = false
    private var output: (@Sendable (Data) -> Bool)?
    private var failed: (@Sendable (Error) -> Void)?
    private var failure: Error?
    private var finishError: Error?
    private var retirementError: Error? // guarded by lock
    /// Process retirement waits for native cleanup, which can take long or not return (a decoder
    /// blocked in the driver); it runs here, so the serial worker keeps serving every other
    /// process. The surface controller is shared with the worker under surfaceLock.
    private let retirements = DispatchQueue(label: "caboose.gpu.retire")
    private let surfaceLock = NSLock()
    private var retiring = Set<UInt64>() // guarded by lock
    private var decodingFailed = false
    /// The charge of the input the serial consumer is handling (worker only).
    private var ingressHold: LiveGPUIngressHold?
    // Suspension, all on the serial worker except nativeSuspended (guarded by lock).
    private var suspendSent = false
    private var quiesceReceived = false
    private var resumeAfterQuiesce = false
    private var holding = false
    private var held: [LiveGPUEnvelope] = []
    private var heldRevocations: [LiveGPUSurfaceIdentity] = []
    private var nativeSuspended = false
    private var onQuiesced: (@Sendable () -> Void)?
    /// The native suspension did not reach an idle GPU in time (a command still ran).
    private(set) var quiesceIncomplete = false
    /// Sends EXECUTOR_STATS at the interval STATS_REQUEST asked for (guarded by lock).
    private var statsTimer: DispatchSourceTimer?

    /// Opens the process-wide native gate: an app in the foreground with no suspended executor
    /// must always decode, whatever an ended executor left behind.
    static func allowDecoding() {
        #if canImport(CabooseGPULive)
        _ = LinkedLiveGPURuntime().resume()
        #endif
    }
    public convenience init(maxPacket: Int = 16 * 1024 * 1024, maxReplyBuffer: Int = 1024 * 1024) throws {
        #if canImport(CabooseGPULive)
        try self.init(backend: LinkedLiveGPURuntime(), maxPacket: maxPacket, maxReplyBuffer: maxReplyBuffer)
        #else
        throw LiveGPUError.missingNativeBinding
        #endif
    }
    #if canImport(UIKit)
    /// Explicit owner-only construction. Ordinary display and agent sessions do
    /// not create presentation registries or acquire a Metal layer.
    public convenience init(presentationOwners: LiveGPUPresentationOwners,
                            cacheRoot: URL? = nil,
                            maxPacket: Int = 16 * 1024 * 1024,
                            maxReplyBuffer: Int = 1024 * 1024) throws {
        #if canImport(CabooseGPULive)
        try self.init(backend: LinkedLiveGPURuntime(), maxPacket: maxPacket,
            maxReplyBuffer: maxReplyBuffer,
            surfaces: LiveGPUSurfaceController(backend: LinkedLiveGPUSurfaces(owners: presentationOwners)),
            cacheRoot: cacheRoot)
        #else
        throw LiveGPUError.missingNativeBinding
        #endif
    }
    #endif
    init(backend: LiveGPURuntimeBackend, maxPacket: Int = 16 * 1024 * 1024,
         maxReplyBuffer: Int = 1024 * 1024, executor: Data? = nil, generation: UInt64? = nil,
         surfaces: LiveGPUSurfaceController? = nil, cacheRoot: URL? = nil) throws {
        guard (8...400 * 1024 * 1024).contains(maxPacket), (4096...1024 * 1024).contains(maxReplyBuffer) else {
            throw LiveGPUBindingError.protocolViolation("invalid native buffer limits")
        }
        self.backend = backend; self.maxPacket = maxPacket; maxReply = maxReplyBuffer
        self.surfaces = surfaces
        self.cacheRoot = cacheRoot
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
    public func consume(_ bytes: Data) throws { try consume(bytes, release: {}) }
    /// The serial consumer's input: `release` runs once every stream payload in `bytes` is in
    /// its stream's socket or dropped, so the session's ingress charge bounds queued input.
    func consume(_ bytes: Data, release: @escaping @Sendable () -> Void) throws {
        let hold = LiveGPUIngressHold(release)
        ingressHold = hold
        defer { ingressHold = nil; hold.release() }
        guard lock.withLock({ started && !cancelled && !finished && !peerRevoked }) else { throw LiveGPUError.closed }
        do {
            let algorithm = lock.withLock { compression }
            if let algorithm {
                guard decoder.atFrameBoundary else { throw LiveGPUBindingError.protocolViolation("fragmented compressed transport") }
                if LiveGPUCompression.isCompressed(bytes) {
                    let decoded: Data
                    switch algorithm {
                    case .deflate: decoded = try LiveGPUCompression.decode(bytes)
                    case .zstdStream:
                        guard let zstd else { throw LiveGPUCompression.invalid() }
                        decoded = try zstd.decode(bytes)
                    }
                    try decoder.feed(decoded) { try handle($0) }
                } else {
                    try LiveGPUCompression.requireWholeEnvelope(bytes)
                    // On the zstd stream every DATA envelope is a record of it.
                    if algorithm == .zstdStream, bytes[bytes.startIndex + 6] == 7, bytes[bytes.startIndex + 7] == 0 {
                        throw LiveGPUCompression.invalid()
                    }
                    try decoder.feed(bytes) { try handle($0) }
                }
            } else {
                try decoder.feed(bytes) { try handle($0) }
            }
        }
        catch { decodingFailed = true; fail(error); throw error }
    }
    func ingressCharge(_ bytes: Data) throws -> Int {
        if LiveGPUCompression.isCompressed(bytes) {
            if lock.withLock({ compressedTransport }) {
                return try LiveGPUCompression.admissionCharge(bytes)
            }
            // A malicious peer can queue input while CONFIG is still waiting on
            // the worker. Reserve expansion even then; decoding still requires
            // negotiated mode. Legacy partial DATA that happens to start CGLZ
            // remains ordinary input if it is not a structurally valid record.
            if let charge = try? LiveGPUCompression.admissionCharge(bytes) { return charge }
        }
        return bytes.count
    }
    /// Serial consumer-worker operation. A close before SESSION is retained until
    /// negotiation; no native work or socket is discarded to manufacture retirement.
    public func requestDrain() throws {
        guard lock.withLock({ started && !cancelled && !finished }) else { throw LiveGPUError.closed }
        drainRequested = true
        try sendDrainIfReady()
    }
    /// Serial consumer-worker command. Late UIKit invalidation after retirement
    /// is harmless; it can neither resurrect a surface nor target a new generation.
    func requestSurfaceRevocation(_ identity: LiveGPUSurfaceIdentity) throws {
        guard lock.withLock({ started && !cancelled && !finished }),
              negotiated, !peerRevoked, !drainRequested else { return }
        // A suspended executor sends nothing; the revocation follows its resume.
        if holding || suspendSent { heldRevocations.append(identity); return }
        try surfaceLock.withLock { try surfaces?.requestRevocation(identity) { [self] process, message in
            try send(message.kind, process: process, payload: message.encoded())
        } }
    }
    func suspend(quiesced: @escaping @Sendable () -> Void) throws -> Bool {
        guard lock.withLock({ started && !cancelled && !finished }), negotiated, !peerRevoked,
              !drainRequested, !suspendSent else { return false }
        // The gate closes before the broker hears of it: commands already here wait as well.
        // Marked first, so a revoke racing this call always opens the gate again.
        guard lock.withLock({ () -> Bool in
            guard !cancelled else { return false }
            nativeSuspended = true
            return true
        }) else { return false }
        let result = backend.suspend(timeoutMilliseconds: 1000)
        guard result == 0 || result == ETIMEDOUT || result == EIO else { openNativeGate(); return false }
        // A revoke while the gate was closing: it may have opened the gate before this closed it.
        if lock.withLock({ cancelled }) { _ = backend.resume(); return false }
        quiesceIncomplete = result != 0
        holding = true; onQuiesced = quiesced
        try send(.executorSuspend)
        suspendSent = true
        return true
    }
    func resumeExecutor() throws {
        guard suspendSent, !peerRevoked else { return }
        openNativeGate()
        holding = false
        let frames = held; held = []
        if quiesceReceived { try finishResume() } else { resumeAfterQuiesce = true }
        for frame in frames { try handle(frame) }
    }
    private func openNativeGate() {
        if lock.withLock({ () -> Bool in defer { nativeSuspended = false }; return nativeSuspended }) {
            _ = backend.resume()
        }
    }
    private func finishResume() throws {
        try send(.executorResume, payload: Data(count: 8))
        suspendSent = false; quiesceReceived = false; resumeAfterQuiesce = false; onQuiesced = nil
        let revocations = heldRevocations; heldRevocations = []
        for identity in revocations { try requestSurfaceRevocation(identity) }
    }
    /// After QUIESCE: every reply the parked decoders wrote has been handed to the transport.
    private func waitForReplies() {
        let deadline = Date().addingTimeInterval(1)
        var quietChecks = 0
        while quietChecks < 2 && Date() < deadline {
            let streams = lock.withLock { processes.values.flatMap { p in p.lock.withLock { Array(p.streams.values) } } }
            let quiet = streams.allSatisfy { !$0.replying && $0.unreadReplies == 0 }
            quietChecks = quiet ? quietChecks + 1 : 0
            if quietChecks < 2 { Thread.sleep(forTimeInterval: 0.01) }
        }
    }
    /// Every `interval` ms, the executor's counters to the computer; none while suspended,
    /// and they end with the binding.
    private func startStats(every interval: UInt32) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "caboose.gpu.stats"))
        timer.schedule(deadline: .now() + .milliseconds(Int(interval)), repeating: .milliseconds(Int(interval)),
                       leeway: .milliseconds(Int(interval / 10)))
        timer.setEventHandler { [weak self] in
            guard let self, !self.lock.withLock({ self.cancelled || self.nativeSuspended }),
                  let stats = self.backend.executorStats() else { return }
            do { try self.send(.executorStats, payload: stats.payload) } catch { timer.cancel() }
        }
        let ended = lock.withLock { () -> Bool in
            if cancelled { return true }
            statsTimer = timer
            return false
        }
        if !ended { timer.resume() }
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
            // The caches are an optimisation: without them (a failure selects none) the
            // computer sends every module.
            _ = backend.setCacheRoot(cacheRoot?.path)
            identity = (frame.executor, frame.generation); negotiated = true
            try send(.sessionReady, payload: LiveGPUEnvelope.hello)
            try sendDrainIfReady()
            return
        }
        if holding, frame.kind != .quiesce, frame.kind != .revoke {
            held.append(frame); return
        }
        switch frame.kind {
        case .statsRequest:
            guard let interval = LiveGPUExecutorStats.requestedInterval(frame.payload),
                  lock.withLock({ statsTimer == nil }) else {
                throw LiveGPUBindingError.protocolViolation("unexpected stats request")
            }
            startStats(every: interval)
        case .quiesce:
            guard suspendSent, !quiesceReceived else {
                throw LiveGPUBindingError.protocolViolation("unexpected QUIESCE")
            }
            quiesceReceived = true
            if holding { waitForReplies() }
            try send(.quiesced)
            onQuiesced?()
            if resumeAfterQuiesce { try finishResume() }
        case .transportConfig:
            guard let algorithm = LiveGPUCompression.algorithm(ofOffer: frame.payload), lastProcess == 0,
                  !drainRequested, !lock.withLock({ compressedTransport }),
                  let answer = LiveGPUCompression.answer(toOffer: frame.payload, windowLog: zstdWindowLog()) else {
                throw LiveGPUBindingError.protocolViolation("unexpected compression negotiation")
            }
            if let windowLog = answer.windowLog {
                zstd = try LiveGPUZstdStream(windowLog: windowLog)
                print("CABOOSE_GPU_COMPRESSION algorithm=2 window_log=\(windowLog)")
            }
            // Publish the accounting mode before admitting the acknowledgement.
            lock.withLock { compression = algorithm }
            try send(.transportReady, payload: answer.payload)
        case .processOpen:
            // An opening the phone cannot honour is left unanswered and logged; the executor and
            // every other process go on (the broker ends the waiting process).
            guard !openedProcesses.contains(frame.process), lock.withLock({ processes.count < 16 }) else {
                return dropped("process open", frame)
            }
            var token: UInt64 = 0
            let result = backend.open(&token)
            guard result == 0 else { throw LiveGPUBindingError.native(operation: "open", code: result) }
            guard token > 0 else { throw LiveGPUBindingError.protocolViolation("native open returned zero token") }
            let process = LiveGPUProcess(token)
            let revoked = lock.withLock { processes[frame.process] = process; return cancelled }
            if revoked { process.stop(backend); throw LiveGPUError.closed }
            openedProcesses.insert(frame.process)
            lastProcess = max(lastProcess, frame.process)
            try send(.processReady, process: frame.process)
        case .streamOpen:
            try openStream(frame)
        case .data, .fin:
            guard let process = lock.withLock({ processes[frame.process] }) else { return dropped("stream data", frame) }
            guard let (stream, ended) = process.lock.withLock({ () -> (LiveGPUDuplex, Bool)? in
                guard let stream = process.streams[frame.stream], !stream.inboundFinished else { return nil }
                if frame.kind == .fin { stream.inboundFinished = true }
                return (stream, stream.nativeEnded)
            }) else {
                // Input for a stream that is gone or already ended belongs to nobody.
                return dropped("stream data", frame)
            }
            if frame.kind == .data { if !ended { stream.enqueue(frame.payload, hold: ingressHold) } }
            else { stream.enqueueFin() }
        case .surfaceBind, .surfaceQuery, .present, .surfaceRetire, .swapchainCreate, .swapchainMap, .swapchainAcquire, .swapchainCancelAcquire, .swapchainRetire, .swapchainPresent, .swapchainPresentOrdered:
            guard let surfaces else { throw LiveGPUBindingError.protocolViolation("presentation is unavailable") }
            let message = try LiveGPUSurfaceMessage.decode(kind: frame.kind, payload: frame.payload)
            guard let process = lock.withLock({ processes[frame.process] }) else {
                dropped("surface record", frame)
                return try surfaceLock.withLock { try surfaces.answerForUnknownProcess(message, process: frame.process) { [self] id, reply in
                    try send(reply.kind, process: id, payload: reply.encoded())
                } }
            }
            try surfaceLock.withLock { try surfaces.consume(message, process: frame.process, token: process.token,
                output: { [self] id, reply in
                    try send(reply.kind, process: id, payload: reply.encoded())
                }, failed: { [self] in fail($0) }) }
        case .processStop:
            // A process the phone does not have is already retired.
            guard let process = lock.withLock({ processes[frame.process] }) else {
                dropped("process stop", frame)
                return try send(.processRetired, process: frame.process)
            }
            // Once: a repeated stop for a process already retiring adds nothing.
            guard lock.withLock({ retiring.insert(frame.process).inserted }) else { return }
            process.stop(backend)
            let id = frame.process
            retirements.async { [self] in
                do {
                    try retire(id, process)
                    try send(.processRetired, process: id)
                } catch { fail(error) }
            }
        case .revoke:
            // A hold that ended: nothing resumes, and every process retires as usual.
            holding = false; held = []
            openNativeGate()
            peerRevoked = true
            // Retirements already under way finish first; REVOKED follows every one.
            retirements.sync {}
            let snapshot = lock.withLock { processes }
            for process in snapshot.values { process.stop(backend) }
            for (id, process) in snapshot.sorted(by: { $0.key < $1.key }) {
                try retire(id, process)
                try send(.processRetired, process: id)
            }
            try send(.revoked)
            lock.withLock { receiptSent = true }
        default: throw LiveGPUBindingError.protocolViolation("unexpected peer message")
        }
    }
    /// Returns once every process retirement started so far has finished (tests, finish).
    func waitForRetirements() { retirements.sync {} }
    /// A peer record that names a process or stream this executor does not have.
    private func dropped(_ what: String, _ frame: LiveGPUEnvelope) {
        print("CABOOSE_GPU_DROPPED \(what) kind=\(frame.kind.rawValue) process=\(frame.process) stream=\(frame.stream) " +
              "sequence=\(frame.sequence) last_process=\(lastProcess) last_stream=\(lastStream) " +
              "processes=\(lock.withLock { processes.count })")
        fflush(stdout)
    }
    private func process(_ id: UInt64) throws -> LiveGPUProcess {
        guard let process = lock.withLock({ processes[id] }) else { throw LiveGPUBindingError.protocolViolation("unknown process") }
        return process
    }
    private func openStream(_ frame: LiveGPUEnvelope) throws {
        guard let process = lock.withLock({ processes[frame.process] }) else { return dropped("stream open", frame) }
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
        // A reused identity is dropped; an opening past capacity is refused with FIN, which the
        // broker reports to that process alone. The executor goes on either way.
        guard !openedStreams.contains(frame.stream) else { return dropped("stream open", frame) }
        guard count < 64 else {
            dropped("stream open over capacity", frame)
            openedStreams.insert(frame.stream); lastStream = max(lastStream, frame.stream)
            return try send(.fin, process: frame.process, stream: frame.stream)
        }
        let stream = try LiveGPUDuplex()
        // Reserve every worker before publishing the descriptors to concurrent revoke.
        stream.workers.enter(); stream.workers.enter(); stream.workers.enter()
        process.lock.withLock {
            process.streams[frame.stream] = stream
            if process.stopped { stream.cancel() }
        }
        openedStreams.insert(frame.stream); lastStream = max(lastStream, frame.stream)
        let gate = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            defer { stream.workers.leave() }
            gate.wait()
            stream.beginNativeRun()
            let result = backend.run(process.token, fd: stream.native, maxPacket: maxPacket, maxReply: maxReply)
            stream.endNativeRun()
            // Native does not own the fd. Its write half ends only after run returns.
            shutdown(stream.native, SHUT_WR)
            let expectedStreamEnd = process.lock.withLock {
                (result == ECANCELED && process.stopped) ||
                (result == EPROTO && (process.stopped || stream.inboundFinished))
            }
            if result != 0 && !expectedStreamEnd {
                // One stream's failure (a refused feed, a malformed command) ends that stream:
                // its write half closed above sends FIN, and the session and every other
                // stream go on. Its writer drops what is still queued.
                process.lock.withLock { stream.nativeEnded = true }
            }
        }
        Thread.detachNewThread { [self] in
            defer { stream.workers.leave() }
            gate.wait()
            stream.runWriter(discard: { process.lock.withLock { stream.nativeEnded || process.stopped } },
                             failed: { [self] error in self.fail(error) })
        }
        Thread.detachNewThread { [self] in
            defer { stream.workers.leave() }
            gate.wait()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                // Poll before read so bridge never enters XNU sbwait on an empty buffer
                // while native is concurrently calling shutdown(native, SHUT_WR).
                var pfd = pollfd(fd: stream.bridge, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pfd, 1, 2)
                if ready < 0 {
                    if errno == EINTR { continue }
                    if process.lock.withLock({ process.stopped }) { return }
                    fail(LiveGPUBindingError.system(operation: "poll", code: errno)); return
                }
                if ready == 0 {
                    if process.lock.withLock({ process.stopped }) { return }
                    stream.nudgeNativeReaderIfDisconnected()
                    continue
                }
                stream.replying = true
                defer { stream.replying = false }
                let count = Darwin.read(stream.bridge, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
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
        defer { gate.signal(); gate.signal(); gate.signal() }
        try send(.streamReady, process: frame.process, stream: frame.stream)
    }
    private func retire(_ id: UInt64, _ process: LiveGPUProcess) throws {
        process.enter("stopping")
        process.stop(backend)
        process.enter("joining streams")
        let streams = process.lock.withLock { Array(process.streams.values) }
        // Bounded: a decoder that does not return (blocked in the driver) keeps its stream and
        // descriptors, and the process stays unfinished, but the others' retirement goes on.
        let deadline = DispatchTime.now() + .seconds(Self.streamJoinSeconds)
        let unjoined = streams.filter { !$0.waitForWorkers(until: deadline) }
        if !unjoined.isEmpty {
            print("CABOOSE_GPU_TEARDOWN_STREAMS token=\(process.token) unjoined=\(unjoined.count)")
            backend.reportTeardown()
            let error = LiveGPUBindingError.native(operation: "join streams", code: ETIMEDOUT)
            process.enter("streams not returned")
            lock.withLock { retirementError = error }; throw error
        }
        process.lock.withLock {
            for stream in process.streams.values { stream.closeAfterJoin() }
            process.streams.removeAll()
        }
        process.enter("retiring surfaces")
        do { try surfaceLock.withLock { try surfaces?.retireProcess(id) } }
        catch {
            process.enter("surfaces not retired")
            lock.withLock { retirementError = error }; throw error
        }
        process.enter("native finish")
        let result = backend.finish(process.token)
        process.enter("finished")
        lock.withLock { _ = processes.removeValue(forKey: id); retiring.remove(id) }
        if result != 0 {
            let error = LiveGPUBindingError.native(operation: "finish", code: result)
            lock.withLock { retirementError = error }; throw error
        }
        if let error = process.lock.withLock({ process.cleanupError }) { lock.withLock { retirementError = error }; throw error }
    }
    /// How long retirement waits for a process's streams' decoders to return.
    static let streamJoinSeconds = 5
    func reportTeardown() {
        let snapshot = lock.withLock { processes }
        let now = Date()
        for (id, process) in snapshot.sorted(by: { $0.key < $1.key }) {
            let (step, since, streams) = process.lock.withLock { (process.teardownStep, process.teardownSince, process.streams.count) }
            print("CABOOSE_GPU_TEARDOWN_STEP process=\(id) token=\(process.token) step=\"\(step)\" " +
                  "age_ms=\(Int(now.timeIntervalSince(since) * 1000)) streams=\(streams)")
        }
        backend.reportTeardown()
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
        // A suspended gate would hold stopping decoders only until they see the stop; open it.
        // Cancelled first, so a suspension still closing the gate opens it again itself.
        let (suspended, snapshot, timer) = lock.withLock { () -> (Bool, [LiveGPUProcess], DispatchSourceTimer?) in
            cancelled = true
            defer { nativeSuspended = false; statsTimer = nil }
            return (nativeSuspended, Array(processes.values), statsTimer)
        }
        timer?.cancel()
        if suspended { _ = backend.resume() }
        for process in snapshot { process.stop(backend) }
        if let error = snapshot.compactMap({ p in p.lock.withLock { p.cleanupError } }).first { throw error }
    }
    public func finish() throws {
        if finished { if let finishError { throw finishError }; return }
        retirements.sync {}
        var error: Error? = lock.withLock { retirementError }
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
