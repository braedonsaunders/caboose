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
        let resource: any LiveGPUSurfaceResource
        var lastSerial: UInt64 = 0
        var receipts: LiveGPUPresentReceipts?
        var retiring = false
    }
    private let backend: any LiveGPUSurfaceBackend
    private var entries: [Data: Entry] = [:]
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
            try output(process, LiveGPUSurfaceMessage(identity: identity, body: body))
        }
        if case let .bind(window, instance, width, height) = message.body {
            guard entries[identity.grant] == nil else { throw violation("duplicate grant") }
            guard entries.count < limit else {
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
        switch message.body {
        case .query(let request, let physical):
            guard !entry.retiring else { throw violation("query during retirement") }
            let (status, capabilities) = entry.resource.query(physicalDevice: physical)
            guard status.querySucceeded == (capabilities != nil) else { throw violation("incomplete native query") }
            try emit(.capabilities(request: request, status: status, value: capabilities))
        case .present(let request):
            guard !entry.retiring, request.serial > entry.lastSerial else { throw violation("stale present") }
            let receipts = LiveGPUPresentReceipts(serial: request.serial, emit: emit, failed: failed)
            let result = entry.resource.present(request) { receipts.receive($0) }
            entry.lastSerial = request.serial
            // Native joins and destroys the previous frame before a new QUEUED
            // or UNCERTAIN return. REJECTED does not establish that boundary.
            if result.disposition != .rejected { entry.receipts = receipts }
            entries[identity.grant] = entry
            try receipts.submit(result)
        case .retire:
            entry.retiring = true; entries[identity.grant] = entry
            do { try entry.resource.retire() }
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

    /// Must finish before runtime_finish: an attached layer holds an instance
    /// lease which upstream process cleanup waits for. Errors preserve entries.
    func retireProcess(_ process: UInt64) throws {
        var firstError: Error?
        for (grant, var entry) in entries where entry.process == process {
            entry.retiring = true; entries[grant] = entry
            do { try entry.resource.retire(); entries.removeValue(forKey: grant) }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
    private func violation(_ reason: String) -> LiveGPUBindingError {
        .protocolViolation("surface " + reason)
    }
}
