import Foundation
import Darwin

protocol LiveGPUIndexedSurfaceResource: LiveGPUSurfaceResource {
    func create(_ info: LiveGPUSwapchainCreate) -> (LiveGPUSurfaceStatus, (any LiveGPUIndexedSwapchain)?)
    /// Blocks until the process's device stream has decoded ORDER mark `serial`; 0 or an
    /// errno (ECANCELED once the process stops). CPU ordering only, never GPU work.
    func waitOrder(_ serial: UInt64) -> Int32
}
protocol LiveGPUIndexedSwapchain: AnyObject, Sendable {
    var id: UInt64 { get }
    var imageCount: UInt32 { get }
    func map(_ images: [UInt64]) -> LiveGPUSurfaceStatus
    func beginAcquire(_ info: LiveGPUSwapchainAcquire) -> (LiveGPUSurfaceStatus, (any LiveGPUAcquireOperation)?)
    func present(_ info: LiveGPUIndexedPresent,
                 event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission
    func retire() -> LiveGPUSurfaceStatus
}

/// One off-consumer worker per retained surface. A shared executor budget bounds
/// captured controls; polling yields this queue so CANCEL and other controls run.
/// Native callbacks enqueue bounded bookkeeping work and never reenter native.
final class LiveGPUIndexedSurface: @unchecked Sendable {
    private final class Swapchain {
        let native: any LiveGPUIndexedSwapchain
        var mapped = false
        var polling: UInt64?
        var lastCompleted: UInt64 = 0
        var tasks: [UInt64: LiveGPUAcquireTask] = [:]
        var ready = Set<UInt32>()
        var pending: [LiveGPUIndexedPresent] = []
        var frames: [UInt64: Frame] = [:]
        var retiring = false
        /// The latest ORDER mark the device stream is known to have decoded.
        var orderReached: UInt64 = 0
        var orderWaiting = false
        init(_ native: any LiveGPUIndexedSwapchain) { self.native = native }
    }
    private struct Frame {
        let index: UInt32
        var result = false
        var released = false
    }
    typealias Emit = @Sendable (LiveGPUSurfaceMessage.Body) throws -> Void
    /// Frames native presentation keeps in flight per surface: the next frame's copy is
    /// queued while the previous one presents.
    static let framesInFlight = 2
    private let resource: any LiveGPUIndexedSurfaceResource
    private let acquireBudget: LiveGPUBudget
    private let budget: LiveGPUBudget
    private let queue = DispatchQueue(label: "caboose.gpu.indexed-surface")
    /// Order waits block here, never on the surface worker that handles callbacks.
    private let orderQueue = DispatchQueue(label: "caboose.gpu.indexed-present-order")
    private let emit: Emit
    private let failed: @Sendable (Error) -> Void
    private var swaps: [UInt64: Swapchain] = [:]
    private var lastSwapchain: UInt64 = 0
    private var revoking = false
    private var failure: Error?
    private var retirement: (() -> Void)?

    init(resource: any LiveGPUIndexedSurfaceResource, budget: LiveGPUBudget,
         acquireBudget: LiveGPUBudget = LiveGPUBudget(), emit: @escaping Emit, failed: @escaping @Sendable (Error) -> Void) {
        self.resource = resource; self.budget = budget; self.acquireBudget = acquireBudget; self.emit = emit; self.failed = failed
    }
    func enqueue(_ control: LiveGPUSwapchainMessage) throws {
        let size = try control.encodedFields().count + 40
        if let error = budget.admit(size) { throw error }
        queue.async { [self] in
            defer { budget.release(size) }
            do { try handle(control) } catch { poison(error) }
        }
    }
    func query(physicalDevice: UInt64) -> (LiveGPUSurfaceStatus, LiveGPUSurfaceCapabilities?) {
        queue.sync {
            guard !revoking, failure == nil else { return (.init(nativeErrno: ESTALE, vkResult: nil), nil) }
            return resource.query(physicalDevice: physicalDevice)
        }
    }
    private func output(_ body: LiveGPUSurfaceMessage.Body) throws {
        do { try emit(body) }
        catch LiveGPUError.closed { if !revoking { failed(LiveGPUError.closed) } }
        catch LiveGPUBindingError.outputRejected { if !revoking { failed(LiveGPUBindingError.outputRejected) } }
    }
    private func reply(_ body: LiveGPUSwapchainMessage) throws { try output(.swapchain(body)) }
    private func handle(_ control: LiveGPUSwapchainMessage) throws {
        if let failure { throw failure }
        guard !revoking else { throw violation("control during retirement") }
        switch control {
        case .create(let info):
            guard swaps.count < 4 else { try reply(.created(request: info.request, swapchain: 0,
                status: .init(nativeErrno: ENOSPC, vkResult: nil), count: 0)); return }
            let (status, native) = resource.create(info)
            if let native {
                // Even an inconsistent success must retain the native object.
                guard native.id > lastSwapchain, swaps[native.id] == nil else {
                    throw violation("native reused swapchain identity")
                }
                swaps[native.id] = Swapchain(native); lastSwapchain = native.id
                guard status.querySucceeded, (1...256).contains(native.imageCount) else {
                    throw violation("native create result/resources disagree")
                }
                try reply(.created(request: info.request, swapchain: native.id, status: status, count: native.imageCount))
            } else {
                guard !status.querySucceeded else { throw violation("missing native swapchain") }
                try reply(.created(request: info.request, swapchain: 0, status: status, count: 0))
            }
        case .map(let id, let images):
            let swap = try active(id)
            guard !swap.mapped, images.count == Int(swap.native.imageCount) else { throw violation("map count/state") }
            let status = swap.native.map(images)
            swap.mapped = status.succeeded
            try reply(.mapped(swapchain: id, status: status))
        case .acquire(let info):
            let swap = try active(info.swapchain)
            guard swap.mapped else { throw violation("acquire before map") }
            guard swap.polling == nil, swap.tasks.count < 256 else {
                try reply(.acquired(swapchain: info.swapchain, request: info.request,
                    status: .init(nativeErrno: EBUSY, vkResult: nil), index: nil, reason: .other)); return
            }
            if let error = acquireBudget.admit(0) { throw error }
            let (status, operation) = swap.native.beginAcquire(info)
            guard let operation else {
                acquireBudget.release(0)
                guard !status.succeeded else { throw violation("missing native acquire") }
                swap.lastCompleted = info.request
                try reply(.acquired(swapchain: info.swapchain, request: info.request, status: status, index: nil,
                    reason: status.vkResult == nil ? .other : .none)); return
            }
            guard status.succeeded else { throw violation("native acquire status/resources disagree") }
            swap.polling = info.request
            // Fence observation must not wait behind a native surface operation:
            // decoder reset/destruction can itself wait on this signal lease.
            let observationQueue = DispatchQueue(label: "caboose.gpu.acquire-observer")
            let task = LiveGPUAcquireTask(operation: operation, queue: observationQueue, timeoutNanoseconds: info.timeoutNanoseconds,
                completion: { [self, swap] result in
                    queue.async { [self, swap] in
                        swap.polling = nil; swap.lastCompleted = info.request
                        do { try reply(.acquired(swapchain: info.swapchain, request: info.request,
                            status: result.status, index: result.index, reason: result.reason)) }
                        catch { poison(error) }
                    }
                }, signalReady: { [self, swap] index in
                    queue.async { [self, swap] in
                        guard index < swap.native.imageCount else { poison(violation("native acquire index")); return }
                        swap.ready.insert(index)
                    }
                }, finished: { [self, swap] error in
                    queue.async { [self, swap] in
                        if let error { poison(error) }
                        else { swap.tasks.removeValue(forKey: info.request); acquireBudget.release(0) }
                        advance()
                    }
                })
            swap.tasks[info.request] = task; task.start()
        case .cancelAcquire(let id, let request):
            let swap = try active(id)
            if let task = swap.tasks[request] { task.cancel() }
            else if request != swap.lastCompleted { throw violation("stale acquire cancellation") }
        case .present(let info):
            let swap = try active(info.swapchain)
            guard swap.mapped, info.index < swap.native.imageCount,
                  !swap.pending.contains(where: { $0.index == info.index }), swap.pending.count < 64 else {
                throw violation("indexed present admission")
            }
            // The original wait set remains unconsumed while actual acquire
            // signalling or the previous native frame is still completing.
            swap.pending.append(info); advance()
        case .retire(let id):
            let swap = try active(id)
            swap.retiring = true
            for task in swap.tasks.values { task.cancel() }
            rejectPending(swap)
            advance()
        default: throw violation("wrong-direction indexed control")
        }
    }
    private func active(_ id: UInt64) throws -> Swapchain {
        guard let value = swaps[id], !value.retiring else { throw violation("unknown/retiring swapchain") }
        return value
    }
    private func advance() {
        guard failure == nil else { retirement?(); return }
        for (id, swap) in swaps {
            if swap.retiring || revoking {
                guard swap.tasks.isEmpty, swap.frames.isEmpty else { continue }
                let status = swap.native.retire()
                if status.succeeded { swaps.removeValue(forKey: id) }
                else if revoking {
                    failure = LiveGPUBindingError.native(
                        operation: "indexed retirement",
                        code: status.nativeErrno > 0 ? status.nativeErrno : EIO)
                    retirement?()
                    return
                }
                else { poison(LiveGPUAcquireFailure.provider(status)); return }
                if !revoking {
                    do { try reply(.retired(swapchain: id, status: status)) } catch { poison(error); return }
                }
                continue
            }
            guard let info = swap.pending.first else { continue }
            // An ordered present runs only after the device stream has decoded the work
            // and signals before its ORDER mark; the wait overlaps acquisition.
            if info.order > swap.orderReached {
                if !swap.orderWaiting { awaitOrder(info.order, swap: swap) }
                continue
            }
            guard swap.frames.count < Self.framesInFlight, swap.ready.contains(info.index) else { continue }
            swap.pending.removeFirst()
            swap.frames[info.serial] = Frame(index: info.index)
            let result = swap.native.present(info) { [self] body in
                // Native callback context remains surface-owned through detach.
                if let error = budget.admit(64) { failed(error); return }
                queue.async { [self] in
                    defer { budget.release(64) }
                    receive(body, swapchain: id, serial: info.serial)
                }
            }
            do {
                try output(.presentResult(serial: info.serial, status: result.status,
                                          disposition: result.disposition, event: .submission))
                if result.disposition == .rejected {
                    swap.frames.removeValue(forKey: info.serial)
                    if !swap.pending.isEmpty { queue.async { [self] in advance() } }
                }
                else { swap.frames[info.serial]?.result = true; swap.ready.remove(info.index) }
            } catch { poison(error); return }
        }
        if revoking && swaps.isEmpty { retirement?() }
    }
    private func awaitOrder(_ order: UInt64, swap: Swapchain) {
        swap.orderWaiting = true
        orderQueue.async { [self, swap] in
            let code = resource.waitOrder(order)
            queue.async { [self, swap] in
                swap.orderWaiting = false
                if code == 0 {
                    swap.orderReached = max(swap.orderReached, order)
                } else if let head = swap.pending.first, head.order == order {
                    // The process stopped or cannot be ordered: the present never runs.
                    swap.pending.removeFirst()
                    do { try output(.presentResult(serial: head.serial, status: .init(nativeErrno: code, vkResult: nil),
                                                   disposition: .rejected, event: .submission)) }
                    catch { poison(error); return }
                }
                advance()
            }
        }
    }
    private func receive(_ body: LiveGPUSurfaceMessage.Body, swapchain: UInt64, serial: UInt64) {
        guard let swap = swaps[swapchain], var frame = swap.frames[serial], frame.result else {
            poison(violation("callback without accepted indexed frame")); return
        }
        do {
            switch body {
            case .sourceReleased(let actual):
                guard actual == serial, !frame.released else { throw violation("duplicate/foreign source release") }
                frame.released = true; swap.frames[serial] = frame
                try output(body)
            case .swapchain(.presentRetired(let id, let actual)):
                guard id == swapchain, actual == serial, frame.released else { throw violation("premature frame retirement") }
                swap.frames.removeValue(forKey: serial)
                defer { advance() }
                try output(body)
            case .presentResult(let actual, _, _, let event):
                guard actual == serial, event != .submission else { throw violation("indexed callback result") }
                try output(body)
            default: throw violation("unexpected indexed callback")
            }
        } catch { poison(error) }
    }
    private func rejectPending(_ swap: Swapchain) {
        let pending = swap.pending; swap.pending.removeAll()
        for info in pending {
            do { try output(.presentResult(serial: info.serial, status: .init(nativeErrno: ECANCELED, vkResult: nil),
                                           disposition: .rejected, event: .submission)) }
            catch { poison(error) }
        }
    }
    /// Called only by the off-main consumer during surface/process cleanup.
    /// The worker remains free to observe signals and process final callbacks.
    func retire() throws {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            revoking = true; retirement = { done.signal() }
            for swap in swaps.values {
                swap.retiring = true
                for task in swap.tasks.values { task.cancel() }
                rejectPending(swap)
            }
            advance()
        }
        guard done.wait(timeout: .now() + 12) == .success else {
            throw LiveGPUBindingError.native(operation: "indexed retirement", code: ETIMEDOUT)
        }
        var result: Error?
        queue.sync { result = failure }
        if let result { throw result }
    }
    private func poison(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        // Cancellation wakes polling tasks; real acquired signals still need observation.
        for swap in swaps.values { for task in swap.tasks.values { task.cancel() } }
        retirement?(); failed(error)
    }
    private func violation(_ reason: String) -> LiveGPUBindingError { .protocolViolation(reason) }
}
