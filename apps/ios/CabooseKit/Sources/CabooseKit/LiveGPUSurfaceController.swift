import Foundation
import Darwin

/// Internal presentation boundary. All operations run on the consumer worker;
/// the linked backend dispatches only layer attach/detach to main. No backend
/// may report retirement until both native GPU retirement and main detach finish.
protocol LiveGPUSurfaceBackend: AnyObject, Sendable {
    func bind(identity: LiveGPUSurfaceIdentity, processToken: UInt64, window: UInt64,
              instance: UInt64, width: UInt32, height: UInt32) throws -> LiveGPUSurfaceBinding
}
struct LiveGPUSurfaceBinding {
    let status: LiveGPUSurfaceStatus
    // Failed attach may retain a resource whose cleanup is not yet safe. Keep it
    // quarantined so process_finish cannot bypass its decoder-instance lease.
    let resource: (any LiveGPUSurfaceResource)?
}
protocol LiveGPUSurfaceResource: AnyObject, Sendable {
    func query(physicalDevice: UInt64) -> (LiveGPUSurfaceStatus, LiveGPUSurfaceCapabilities?)
    func present(_ request: LiveGPUSurfacePresent,
                 event: @escaping @Sendable (LiveGPUSurfaceMessage.Body) -> Void) -> LiveGPUSurfaceSubmission
    /// A throwing retirement retains the resource and callback context.
    func retire() throws
}
struct LiveGPUSurfaceSubmission: Sendable {
    let status: LiveGPUSurfaceStatus
    let disposition: LiveGPUSurfaceMessage.Disposition
}

/// Native callbacks can arrive synchronously before present returns. Serialize
/// submission and subsequent fence receipts without holding the controller's lock
/// during a native call. One gate remains live for the current native frame.
private final class LiveGPUPresentReceipts: @unchecked Sendable {
    private let lock = NSLock()
    private let serial: UInt64
    private let emit: @Sendable (LiveGPUSurfaceMessage.Body) throws -> Void
    private let failed: @Sendable (Error) -> Void
    private var pending: [LiveGPUSurfaceMessage.Body] = []
    private var admitted = false
    private var poisoned = false
    init(serial: UInt64, emit: @escaping @Sendable (LiveGPUSurfaceMessage.Body) throws -> Void,
         failed: @escaping @Sendable (Error) -> Void) {
        self.serial = serial; self.emit = emit; self.failed = failed
    }
    func receive(_ body: LiveGPUSurfaceMessage.Body) {
        do {
            try lock.withLock {
                guard !poisoned else { return }
                switch body {
                case .sourceReleased(let value):
                    guard value == serial else { throw violation("source serial") }
                case .presentResult(let value, _, _, let event):
                    guard value == serial, event != .submission else { throw violation("callback serial/event") }
                default: throw violation("callback body")
                }
                if admitted { try emit(body) }
                else {
                    guard pending.count < 3 else { throw violation("callback capacity") }
                    pending.append(body)
                }
            }
        } catch { poison(error) }
    }
    func submit(_ result: LiveGPUSurfaceSubmission) throws {
        do {
            try lock.withLock {
                guard !poisoned else { throw violation("callback failed before admission") }
                // The submission receipt precedes every completion even if native
                // completed while its present function was still returning.
                try emit(.presentResult(serial: serial, status: result.status,
                                        disposition: result.disposition, event: .submission))
                if result.disposition == .rejected, !pending.isEmpty {
                    throw violation("rejected submission emitted completion")
                }
                admitted = true
                for body in pending { try emit(body) }
                pending.removeAll()
            }
        } catch { poison(error); throw error }
    }
    private func poison(_ error: Error) {
        let notify = lock.withLock { () -> Bool in
            guard !poisoned else { return false }
            poisoned = true; pending.removeAll(); return true
        }
        if notify { failed(error) }
    }
    private func violation(_ reason: String) -> LiveGPUBindingError {
        .protocolViolation("surface " + reason)
    }
}

/// One controller belongs to one executor. No stale message may acquire a new
/// resource, and a failed detach keeps its reservation until process teardown is
/// explicitly resolved. This object is called serially by the CGLV consumer.
final class LiveGPUSurfaceController: @unchecked Sendable {
    typealias Output = @Sendable (UInt64, LiveGPUSurfaceMessage) throws -> Void
    private struct Entry {
        let process: UInt64
        let identity: LiveGPUSurfaceIdentity
        let resource: (any LiveGPUSurfaceResource)?
        var lastSerial: UInt64 = 0
        var lastRequest: UInt64 = 0
        var indexed: LiveGPUIndexedSurface?
        var receipts: LiveGPUPresentReceipts?
        var retiring = false
        var revokeRequested = false
    }
    private let backend: any LiveGPUSurfaceBackend
    private var entries: [Data: Entry] = [:]
    private let workBudget = LiveGPUBudget()
    private let acquireBudget = LiveGPUBudget()
    private let limit: Int
    init(backend: any LiveGPUSurfaceBackend, limit: Int = 32) {
        precondition(limit > 0 && limit <= 256)
        self.backend = backend; self.limit = limit
    }
    var retainedCount: Int { entries.count }

    func consume(_ message: LiveGPUSurfaceMessage, process: UInt64, token: UInt64,
                 output: @escaping Output, failed: @escaping @Sendable (Error) -> Void) throws {
        let identity = message.identity
        let emit: @Sendable (LiveGPUSurfaceMessage.Body) throws -> Void = { body in
            #if DEBUG && canImport(CabooseGPUMemoryAudit)
            if case .bound(let status) = body { LiveGPUMemoryAudit.surfaceBind(status) }
            #endif
            try output(process, LiveGPUSurfaceMessage(identity: identity, body: body))
        }
        if case let .bind(window, instance, width, height) = message.body {
            guard entries[identity.grant] == nil else { throw violation("duplicate grant") }
            // Every replied-to bind keeps its authenticated identity until retirement,
            // even when no native resource was created. Bound rejected identities
            // as well as native resources; exhaustion terminates admission.
            guard entries.count < 256 else { throw violation("grant capacity") }
            entries[identity.grant] = Entry(process: process, identity: identity, resource: nil, retiring: true)
            guard entries.count <= limit else {
                try emit(.bound(.init(nativeErrno: ENOSPC, vkResult: nil))); return
            }
            do {
                let bound = try backend.bind(identity: identity, processToken: token, window: window,
                                             instance: instance, width: width, height: height)
                if let resource = bound.resource {
                    var entry = Entry(process: process, identity: identity, resource: resource)
                    entry.retiring = !bound.status.succeeded
                    entries[identity.grant] = entry
                } else if bound.status.succeeded { throw violation("bind succeeded without resource") }
                try emit(.bound(bound.status))
            } catch let error as LiveGPUBindingError {
                if case .native(_, let code) = error, code > 0 {
                    try emit(.bound(.init(nativeErrno: code, vkResult: nil))); return
                }
                throw error
            }
            return
        }
        guard var entry = entries[identity.grant], entry.identity == identity, entry.process == process else {
            throw violation("unknown or foreign grant")
        }
        guard let resource = entry.resource else {
            // The backend either never acquired a resource or completed its cleanup
            // before returning failure. Only the exact retained identity may retire.
            guard case .retire = message.body else { throw violation("work after failed bind") }
            entries.removeValue(forKey: identity.grant)
            try emit(.retired(.init(nativeErrno: 0, vkResult: nil)))
            return
        }
        if entry.revokeRequested, !entry.retiring {
            // Peer work already in transit may cross the local revoke request.
            // Return a local rejection while preserving process and source leases.
            switch message.body {
            case .query(let request, _):
                try emit(.capabilities(request: request, status: .init(nativeErrno: ESTALE, vkResult: nil), value: nil))
                return
            case .present(let request):
                guard request.serial > entry.lastSerial else { throw violation("stale present") }
                entry.lastSerial = request.serial; entries[identity.grant] = entry
                try emit(.presentResult(serial: request.serial, status: .init(nativeErrno: ESTALE, vkResult: nil),
                                        disposition: .rejected, event: .submission))
                return
            default: break
            }
        }
        switch message.body {
        case .swapchain(let control):
            guard !entry.retiring else { throw violation("indexed control during retirement") }
            switch control {
            case .create(let info):
                guard info.request > entry.lastRequest else { throw violation("stale create request") }
                entry.lastRequest = info.request
            case .acquire(let info):
                guard info.request > entry.lastRequest else { throw violation("stale acquire request") }
                entry.lastRequest = info.request
            case .present(let info):
                guard info.serial > entry.lastSerial else { throw violation("stale indexed present") }
                entry.lastSerial = info.serial
            default: break
            }
            if entry.revokeRequested {
                switch control {
                case .cancelAcquire, .retire: break
                case .present(let info):
                    entries[identity.grant] = entry
                    try emit(.presentResult(serial: info.serial, status: .init(nativeErrno: ESTALE, vkResult: nil),
                                            disposition: .rejected, event: .submission)); return
                case .acquire(let info):
                    entries[identity.grant] = entry
                    try emit(.swapchain(.acquired(swapchain: info.swapchain, request: info.request,
                        status: .init(nativeErrno: ESTALE, vkResult: nil), index: nil, reason: .other))); return
                case .create(let info):
                    entries[identity.grant] = entry
                    try emit(.swapchain(.created(request: info.request, swapchain: 0,
                        status: .init(nativeErrno: ESTALE, vkResult: nil), count: 0))); return
                case .map(let id, _):
                    try emit(.swapchain(.mapped(swapchain: id, status: .init(nativeErrno: ESTALE, vkResult: nil)))); return
                default: throw violation("wrong-direction indexed message")
                }
            }
            if entry.indexed == nil {
                guard let resource = resource as? any LiveGPUIndexedSurfaceResource else {
                    throw violation("indexed native API unavailable")
                }
                entry.indexed = LiveGPUIndexedSurface(resource: resource, budget: workBudget, acquireBudget: acquireBudget, emit: emit, failed: failed)
            }
            entries[identity.grant] = entry
            try entry.indexed!.enqueue(control)
        case .query(let request, let physical):
            guard !entry.retiring, request > entry.lastRequest else { throw violation("query during retirement or stale request") }
            entry.lastRequest = request; entries[identity.grant] = entry
            let (status, capabilities) = entry.indexed?.query(physicalDevice: physical) ?? resource.query(physicalDevice: physical)
            guard status.querySucceeded == (capabilities != nil) else { throw violation("incomplete native query") }
            try emit(.capabilities(request: request, status: status, value: capabilities))
        case .present(let request):
            guard !entry.retiring, request.serial > entry.lastSerial else { throw violation("stale present") }
            let receipts = LiveGPUPresentReceipts(serial: request.serial, emit: emit, failed: failed)
            let result = resource.present(request) { receipts.receive($0) }
            entry.lastSerial = request.serial
            // Native joins and destroys the previous frame before a new QUEUED
            // or UNCERTAIN return. REJECTED does not establish that boundary.
            if result.disposition != .rejected { entry.receipts = receipts }
            entries[identity.grant] = entry
            try receipts.submit(result)
        case .retire:
            entry.retiring = true; entries[identity.grant] = entry
            do { try entry.indexed?.retire(); try entry.resource?.retire() }
            catch let error as LiveGPUBindingError {
                if case .native(_, let code) = error, code > 0 {
                    try emit(.retired(.init(nativeErrno: code, vkResult: nil))); return
                }
                throw error
            }
            // A failed outgoing receipt still leaves the remote lease fenced.
            entries.removeValue(forKey: identity.grant)
            try emit(.retired(.init(nativeErrno: 0, vkResult: nil)))
        default: throw violation("wrong-direction surface message")
        }
    }

    /// A local view can disappear after the peer has already retired its grant.
    /// Match the complete retained identity, emit once, and await compositor RETIRE.
    func requestRevocation(_ identity: LiveGPUSurfaceIdentity, output: Output) throws {
        guard var entry = entries[identity.grant], entry.identity == identity,
              !entry.retiring, !entry.revokeRequested else { return }
        entry.revokeRequested = true; entries[identity.grant] = entry
        try output(entry.process, .init(identity: identity, body: .swapchain(.revokeSurface)))
    }

    /// Must finish before runtime_finish: an attached layer holds an instance
    /// lease which upstream process cleanup waits for. Errors preserve entries.
    func retireProcess(_ process: UInt64) throws {
        var firstError: Error?
        for (grant, var entry) in entries where entry.process == process {
            entry.retiring = true; entries[grant] = entry
            do { try entry.indexed?.retire(); try entry.resource?.retire(); entries.removeValue(forKey: grant) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
    private func violation(_ reason: String) -> LiveGPUBindingError {
        .protocolViolation("surface " + reason)
    }
}
