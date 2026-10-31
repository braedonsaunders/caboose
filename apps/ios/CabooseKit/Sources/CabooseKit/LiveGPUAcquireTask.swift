import Foundation
import Darwin

/// A single native request. Implementations retain its synchronization leases
/// until release returns zero; a failed release must not free the native pointer.
protocol LiveGPUAcquireOperation: AnyObject, Sendable {
    func poll() -> LiveGPUAcquireCompletion
    func cancel() -> Int32
    func observeSignal() -> LiveGPUSurfaceStatus
    func release() -> Int32
}
struct LiveGPUAcquireCompletion: Equatable, Sendable {
    let status: LiveGPUSurfaceStatus
    let index: UInt32?
    let reason: LiveGPUAcquireLocalReason
    var invalidNativeShape = false
    var acquired: Bool {
        status.nativeErrno == 0 && (status.vkResult == 0 || status.vkResult == 1000001003) && index != nil
    }
    var pending: Bool { status.nativeErrno == 0 && (status.vkResult == 1 || status.vkResult == 2) && index == nil }
    func validate() throws {
        guard !invalidNativeShape else { throw LiveGPUAcquireFailure.contradictoryResult }
        // The independent wire parser also checks contradictory actual/local status.
        _ = try LiveGPUSwapchainMessage.acquired(swapchain: 1, request: 1, status: status,
                                                index: index, reason: reason).encodedFields()
    }
}
enum LiveGPUAcquireFailure: Error, Equatable {
    case native(Int32)
    case provider(LiveGPUSurfaceStatus)
    case contradictoryResult
    case signalDeadline
}

/// Runs on a bounded owner's separate work queue, never the CGLV consumer or
/// decoder queue. Each tick performs one zero-timeout native operation and yields.
/// Polling and cancellation serialize here; an acquired index always wins over
/// cancellation. Signal observation continues after delivering that index.
final class LiveGPUAcquireTask: @unchecked Sendable {
    private enum Phase { case idle, polling, observing, finished, quarantined }
    private let operation: any LiveGPUAcquireOperation
    private let queue: DispatchQueue
    private let timeout: UInt64
    private let interval: UInt64
    private let signalBudget: UInt64
    private let completion: @Sendable (LiveGPUAcquireCompletion) -> Void
    private let signalReady: @Sendable (UInt32) -> Void
    // Failure means the owner MUST retain this task/operation and quarantine its swapchain.
    private let finished: @Sendable (LiveGPUAcquireFailure?) -> Void
    private let cancellation = NSLock()
    private var cancellationRequested = false
    private var phase = Phase.idle
    private var startedAt: UInt64 = 0
    private var observedAt: UInt64 = 0
    private var acquiredIndex: UInt32?
    private var terminalDelivered = false
    private var scheduled: DispatchWorkItem?

    init(operation: any LiveGPUAcquireOperation, queue: DispatchQueue,
         timeoutNanoseconds: UInt64, pollIntervalNanoseconds: UInt64 = 1_000_000,
         signalBudgetNanoseconds: UInt64 = 10_000_000_000,
         completion: @escaping @Sendable (LiveGPUAcquireCompletion) -> Void,
         signalReady: @escaping @Sendable (UInt32) -> Void,
         finished: @escaping @Sendable (LiveGPUAcquireFailure?) -> Void) {
        precondition(pollIntervalNanoseconds > 0 && pollIntervalNanoseconds <= 1_000_000_000)
        self.operation = operation; self.queue = queue; timeout = timeoutNanoseconds
        interval = pollIntervalNanoseconds; signalBudget = signalBudgetNanoseconds
        self.completion = completion; self.signalReady = signalReady; self.finished = finished
    }
    func start() {
        queue.async { [self] in
            guard phase == .idle else { return }
            phase = .polling; startedAt = DispatchTime.now().uptimeNanoseconds
            tick()
        }
    }
    func cancel() {
        cancellation.withLock { cancellationRequested = true }
        queue.async { [self] in
            guard phase == .polling else { return }
            scheduled?.cancel(); scheduled = nil
            tick()
        }
    }
    private func tick() {
        scheduled = nil
        switch phase {
        case .polling:
            if cancellation.withLock({ cancellationRequested }) { resolveCancellation(.cancelled); return }
            let value = operation.poll()
            do { try value.validate() } catch { quarantine(.contradictoryResult); return }
            if value.acquired { accept(value); return }
            if !value.pending { completeAndRelease(value); return }
            if timeout == 0 {
                // Preserve the actual zero-timeout provider result, but cancel
                // and release the unsignalled request before reporting it.
                resolveCancellation(.none, zeroTimeoutResult: value); return
            }
            if timeout != UInt64.max && elapsed(since: startedAt) >= timeout {
                resolveCancellation(.deadline); return
            }
            schedule()
        case .observing:
            let status = operation.observeSignal()
            if status.vkResult == 0 && status.nativeErrno == 0 {
                guard let index = acquiredIndex else { quarantine(.contradictoryResult); return }
                let code = operation.release()
                guard code == 0 else { quarantine(.native(code)); return }
                phase = .finished; signalReady(index); finished(nil)
            } else if status.vkResult == 1 && status.nativeErrno == 0 {
                if elapsed(since: observedAt) >= signalBudget { quarantine(.signalDeadline) }
                else { schedule() }
            } else {
                // A real device loss is retained as such; it is not a timeout,
                // cancellation or successful release of the swapchain itself.
                if status.vkResult == -4 {
                    let code = operation.release()
                    guard code == 0 else { quarantine(.native(code)); return }
                }
                quarantine(.provider(status))
            }
        case .idle, .finished, .quarantined: break
        }
    }
    private func resolveCancellation(_ reason: LiveGPUAcquireLocalReason,
                                     zeroTimeoutResult: LiveGPUAcquireCompletion? = nil) {
        let code = operation.cancel()
        if code == 0 {
            if let zeroTimeoutResult { completeAndRelease(zeroTimeoutResult) }
            else {
                completeAndRelease(.init(status: .init(nativeErrno: reason == .deadline ? ETIMEDOUT : ECANCELED,
                                                       vkResult: nil), index: nil, reason: reason))
            }
            return
        }
        guard code == EALREADY || code == EIO else { quarantine(.native(code)); return }
        // Native keeps the actual winning success or terminal provider error.
        let actual = operation.poll()
        do { try actual.validate() } catch { quarantine(.contradictoryResult); return }
        if actual.acquired { accept(actual) }
        else if !actual.pending && code == EIO { completeAndRelease(actual) }
        else { quarantine(.contradictoryResult) }
    }
    private func accept(_ value: LiveGPUAcquireCompletion) {
        guard !terminalDelivered, let index = value.index else { quarantine(.contradictoryResult); return }
        acquiredIndex = index; phase = .observing
        observedAt = DispatchTime.now().uptimeNanoseconds
        terminalDelivered = true
        completion(value)
        // Start independent signal observation even if the caller's reply send
        // fails: guest fence reset/destruction may be waiting on this lease.
        tick()
    }
    private func completeAndRelease(_ value: LiveGPUAcquireCompletion) {
        let code = operation.release()
        guard code == 0 else { quarantine(.native(code)); return }
        guard !terminalDelivered else { quarantine(.contradictoryResult); return }
        terminalDelivered = true; phase = .finished
        completion(value); finished(nil)
    }
    private func schedule() {
        let task = DispatchWorkItem { [self] in tick() }
        scheduled = task
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(interval)), execute: task)
    }
    private func quarantine(_ error: LiveGPUAcquireFailure) {
        guard phase != .quarantined, phase != .finished else { return }
        scheduled?.cancel(); scheduled = nil; phase = .quarantined
        finished(error)
    }
    private func elapsed(since value: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now >= value ? now - value : 0
    }
}
