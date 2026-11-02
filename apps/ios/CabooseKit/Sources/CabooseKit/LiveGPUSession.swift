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
    /// Serial worker: request peer retirement while the duplex transport stays open.
    func requestDrain() throws
    func revoke() throws
    func finish() throws
}

/// Internal owner-view command; no application-supplied process ID is accepted.
protocol LiveGPUSurfaceRevoking: AnyObject {
    func requestSurfaceRevocation(_ identity: LiveGPUSurfaceIdentity) throws
}

/// Written by the serial consumer only after actual native retirement and an
/// admitted REVOKED receipt. A normal broker close is separately required.
protocol LiveGPURetirementReporting: AnyObject {
    var retirementReceiptSent: Bool { get }
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
    private var draining = false
    /// The transport's receiving is held back while the decoder catches up (under `lock`).
    private var receivePaused = false
    private var confirmedRetirement = false
    public var remoteRetirementCompleted: Bool { lock.withLock { confirmedRetirement } }
    private var drainDeadline: DispatchWorkItem?
    private let drainTimeout: TimeInterval
    /// A cleanup still running after this (a decoder blocked in the driver) no longer holds
    /// the owner back: the executor is reported ended with a failed cleanup, which keeps its
    /// native state for the app's lifetime, and a new one can take over.
    private let cleanupTimeout: TimeInterval
    private var event: (@Sendable (LiveGPUSessionEvent) -> Void)?

    public convenience init(transport: LiveGPUTransport, nativeBinding: LiveGPUByteConsumer?) throws {
        try self.init(transport: transport, nativeBinding: nativeBinding, drainTimeout: 10)
    }
    init(transport: LiveGPUTransport, nativeBinding: LiveGPUByteConsumer?, drainTimeout: TimeInterval,
         cleanupTimeout: TimeInterval = 10) throws {
        guard let nativeBinding else { throw LiveGPUError.missingNativeBinding }
        precondition(drainTimeout.isFinite && drainTimeout > 0 && cleanupTimeout.isFinite && cleanupTimeout > 0)
        self.transport = transport; consumer = nativeBinding; self.drainTimeout = drainTimeout
        self.cleanupTimeout = cleanupTimeout
    }

    public func start(_ event: @escaping @Sendable (LiveGPUSessionEvent) -> Void) {
        lock.lock()
        guard !started, !stopping else { lock.unlock(); return }
        started = true; self.event = event
        lock.unlock()
        transport.open { [weak self] in self?.receive($0) }
    }

    /// Graceful close retains duplex IO for PROCESS_STOP/REVOKE receipts. A broker
    /// close ends the session; expiration forces local cleanup but proves no remote
    /// lease release. A blocked native decoder may prevent graceful retirement.
    public func close() {
        lock.lock()
        guard !stopping, !draining else { lock.unlock(); return }
        guard opened else { lock.unlock(); stop(nil); return }
        draining = true
        let deadline = DispatchWorkItem { [weak self] in self?.stop(LiveGPUError.drainTimedOut) }
        drainDeadline = deadline
        worker.async { [self] in
            guard ingress.active else { return }
            do { try consumer.requestDrain() } catch { stop(error) }
        }
        lock.unlock()
        cleanup.asyncAfter(deadline: .now() + drainTimeout, execute: deadline)
    }

    /// Suspends the executor in place before the app leaves the foreground (docs/gpu-live.md,
    /// "Suspending an executor"). `done(true)` once native decoding has stopped and the broker
    /// was asked to hold; false when this executor cannot suspend (the computer does not
    /// resume executors, or it is closing), so the caller drains it as before. `quiesced`
    /// follows once the broker's hold is confirmed.
    public func suspend(quiesced: @escaping @Sendable () -> Void, done: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        guard started, opened, !stopping, !draining,
              (transport as? LiveGPUResumableTransport)?.negotiatedMode == .resumable,
              let suspending = consumer as? LiveGPUSuspending else { lock.unlock(); done(false); return }
        worker.async { [self] in
            guard ingress.active else { done(false); return }
            do { done(try suspending.suspend(quiesced: quiesced)) } catch { stop(error); done(false) }
        }
        lock.unlock()
    }

    /// Ends a suspension, also one whose QUIESCE has not arrived yet.
    public func resume() {
        lock.lock()
        guard started, !stopping, let suspending = consumer as? LiveGPUSuspending else { lock.unlock(); return }
        (transport as? LiveGPUResumableTransport)?.resumeTransport()
        worker.async { [self] in
            guard ingress.active else { return }
            do { try suspending.resumeExecutor() } catch { stop(error) }
        }
        lock.unlock()
    }

    /// Closes a suspended executor's socket for the background (code 4001) once the broker
    /// has acknowledged everything sent; the host holds the executor for its extended window.
    public func suspendTransport() {
        (transport as? LiveGPUResumableTransport)?.suspendTransport(afterAcknowledgement: 2)
    }

    /// Owner-view invalidation joins the same bounded serial queue as peer input.
    /// It does not close the executor or infer native retirement.
    func requestSurfaceRevocation(_ identity: LiveGPUSurfaceIdentity) {
        lock.lock()
        guard started, opened, !stopping, !draining else { lock.unlock(); return }
        if let error = ingress.admit(40) { lock.unlock(); stop(error); return }
        worker.async { [self] in
            defer { ingress.release(40) }
            guard ingress.active else { return }
            do {
                guard let revoking = consumer as? LiveGPUSurfaceRevoking else {
                    throw LiveGPUError.missingNativeBinding
                }
                try revoking.requestSurfaceRevocation(identity)
            } catch { stop(error) }
        }
        lock.unlock()
    }

    /// Immediate local teardown, including when the caller cannot keep its transport
    /// alive. Remote lease retirement is deliberately not inferred from this result.
    public func abort() { stop(nil) }

    private func receive(_ incoming: LiveGPUTransportEvent) {
        switch incoming {
        case .closed(let error): stop(error, normalPeerClose: error == nil)
        case .opened:
            lock.lock()
            guard !stopping, !opened else { lock.unlock(); return }
            opened = true
            worker.async { [self] in
                guard ingress.active else { return }
                do {
                    try consumer.start(output: { [weak self] bytes in self?.output(bytes) ?? false },
                                       failed: { [weak self] error in self?.stop(error) })
                    if ingress.active { lock.withLock { event }?(.transportOpened) }
                } catch { stop(error) }
            }
            lock.unlock()
        case .bytes(let data):
            lock.lock()
            guard !stopping else { lock.unlock(); return }
            let charge: Int
            do { charge = try (consumer as? LiveGPUIngressAccounting)?.ingressCharge(data) ?? data.count }
            catch { lock.unlock(); stop(error); return }
            if let error = ingress.admit(charge) {
                lock.unlock(); stop(error); return
            }
            // The decoder is behind (several applications connecting at once): hold the
            // socket back until it catches up, rather than overflow and end the executor.
            if !receivePaused, ingress.full {
                receivePaused = true
                (transport as? LiveGPUReceiveFlow)?.setReceivingPaused(true)
            }
            worker.async { [self] in
                defer {
                    ingress.release(charge)
                    let resume = lock.withLock { () -> Bool in
                        guard receivePaused, ingress.drained else { return false }
                        receivePaused = false
                        return true
                    }
                    if resume { (transport as? LiveGPUReceiveFlow)?.setReceivingPaused(false) }
                }
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

    private func stop(_ cause: Error?, normalPeerClose: Bool = false) {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true; ingress.revoke()
        drainDeadline?.cancel(); drainDeadline = nil
        lock.unlock()
        #if DEBUG && canImport(CabooseGPUMemoryAudit)
        LiveGPUMemoryAudit.sessionStop(cause, normalPeerClose: normalPeerClose)
        #endif
        transport.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + cleanupTimeout) { [self] in
            report(cause: cause, cleanupError: LiveGPUError.cleanupTimedOut)
        }
        // A blocked socketpair writer cannot prevent revocation from interrupting it.
        cleanup.async { [self] in
            var revokeError: Error?
            do { try consumer.revoke() } catch { revokeError = error }
            let priorError = revokeError
            worker.async { [self] in
                var cleanupError = priorError
                do { try consumer.finish() } catch { if cleanupError == nil { cleanupError = error } }
                let receipt = (consumer as? any LiveGPURetirementReporting)?.retirementReceiptSent == true
                report(cause: cause, cleanupError: cleanupError,
                       confirmed: normalPeerClose && cause == nil && cleanupError == nil && receipt)
            }
        }
    }

    /// The single end event: from returned cleanup or from the cleanup deadline, whichever is first.
    private func report(cause: Error?, cleanupError: Error?, confirmed: Bool = false) {
        let event = lock.withLock { () -> (@Sendable (LiveGPUSessionEvent) -> Void)? in
            defer { self.event = nil }
            if self.event != nil { confirmedRetirement = confirmed }
            return self.event
        }
        event?(.ended(cause: cause, cleanupError: cleanupError))
    }
}
