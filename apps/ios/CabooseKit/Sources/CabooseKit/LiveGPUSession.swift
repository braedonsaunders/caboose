import Foundation

/// Integration boundary for the authenticated envelope decoder and native runtime binding.
/// There is intentionally no default implementation or diagnostic-provider fallback.
///
/// The binding initializes the single process provider once, negotiates the parent's wire
/// contract, then opens a fresh native token. It never passes envelope/hello bytes to run.
/// start/consume execute on a serial worker, never the main or network queue. start installs
/// callbacks and returns without waiting for inbound negotiation; consume advances that
/// negotiation incrementally. Native run
/// and continuous reply reads need their own workers; output must preserve byte order and
/// fragment messages to 256 KiB. A successful output admission is NOT a GPU completion.
/// revoke runs concurrently: it must latch cancellation even before start, revoke native
/// admission and shutdown socketpair IO to unblock all workers. finish joins native run
/// and reply workers, closes descriptors, and calls native finish, propagating all errors.
/// Neither reconnect nor finish finalizes the process-wide provider. Surface ownership
/// and authenticated window association remain the responsibility of the native binding.
public protocol LiveGPUByteConsumer: AnyObject, Sendable {
    func start(output: @escaping @Sendable (Data) -> Bool,
               failed: @escaping @Sendable (Error) -> Void) throws
    func consume(_ bytes: Data) throws
    func revoke() throws
    func finish() throws
}

public enum LiveGPUSessionEvent: Sendable {
    /// WebSocket accepted. Does not imply native runtime, negotiation or presentation readiness.
    case transportOpened
    /// Cleanup has returned. A failed cleanup forbids replacement admission.
    case ended(cause: Error?, cleanupError: Error?)
}

/// One lease/generation, never restartable. The owner must retain it until ended, and may
/// replace it only after ended with nil cleanupError AND release of the host's old executor.
/// Audio, display hello and legacy replay are intentionally unaffected.
public final class LiveGPUSession: @unchecked Sendable {
    public let generation = UUID()
    private let transport: LiveGPUTransport
    private let consumer: LiveGPUByteConsumer
    private let lock = NSLock()
    private let ingress = LiveGPUBudget()
    private let worker = DispatchQueue(label: "caboose.gpu.consumer")
    private let cleanup = DispatchQueue(label: "caboose.gpu.cleanup")
    private var started = false
    private var stopping = false
    private var opened = false
    private var event: (@Sendable (LiveGPUSessionEvent) -> Void)?

    public init(transport: LiveGPUTransport, nativeBinding: LiveGPUByteConsumer?) throws {
        guard let nativeBinding else { throw LiveGPUError.missingNativeBinding }
        self.transport = transport; consumer = nativeBinding
    }

    public func start(_ event: @escaping @Sendable (LiveGPUSessionEvent) -> Void) {
        lock.lock()
        guard !started, !stopping else { lock.unlock(); return }
        started = true; self.event = event
        lock.unlock()
        transport.open { [weak self] in self?.receive($0) }
    }

    public func close() { stop(nil) }

    private func receive(_ incoming: LiveGPUTransportEvent) {
        switch incoming {
        case .closed(let error): stop(error)
        case .opened:
            lock.lock()
            guard !stopping, !opened else { lock.unlock(); return }
            opened = true
            worker.async { [self] in
                guard ingress.active else { return }
                do {
                    try consumer.start(output: { [weak self] bytes in self?.output(bytes) ?? false },
                                       failed: { [weak self] error in self?.stop(error) })
                    if ingress.active { event?(.transportOpened) }
                } catch { stop(error) }
            }
            lock.unlock()
        case .bytes(let data):
            lock.lock()
            guard !stopping else { lock.unlock(); return }
            if let error = ingress.admit(data.count) {
                lock.unlock(); stop(error); return
            }
            worker.async { [self] in
                defer { ingress.release(data.count) }
                guard ingress.active else { return }
                do { try consumer.consume(data) } catch { stop(error) }
            }
            lock.unlock()
        }
    }

    private func output(_ data: Data) -> Bool {
        // The connection independently reserves the outgoing budget before capturing Data.
        guard ingress.active else { return false }
        guard transport.send(data) else { stop(LiveGPUError.closed); return false }
        return true
    }

    private func stop(_ cause: Error?) {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true; ingress.revoke()
        lock.unlock()
        transport.close()
        // A blocked socketpair writer cannot prevent revocation from interrupting it.
        cleanup.async { [self] in
            var revokeError: Error?
            do { try consumer.revoke() } catch { revokeError = error }
            let priorError = revokeError
            worker.async { [self] in
                var cleanupError = priorError
                do { try consumer.finish() } catch { if cleanupError == nil { cleanupError = error } }
                event?(.ended(cause: cause, cleanupError: cleanupError))
                event = nil
            }
        }
    }
}
