#if DEBUG && canImport(CabooseGPUMemoryAudit)
import Foundation
import CabooseGPUMemoryAudit

/// Explicit diagnostic package + launch opt-in. Only feature flags, allocation
/// indices/sizes and provider results are recorded; never memory contents or credentials.
enum LiveGPUMemoryAudit {
    private static let requested = ProcessInfo.processInfo.environment["CABOOSE_PRIVATE_GPU_MEMORY_AUDIT"] == "1"
    private static let terminalLock = NSLock()
    nonisolated(unsafe) private static var terminalCount = 0
    static func enable() -> Int32 { caboose_gpu_runtime_enable_memory_audit() }

    // Fixed metadata only, bounded for the lifetime of this diagnostic app process.
    private static func terminal(_ fields: [String: Any]) {
        guard requested else { return }
        let ordinal = terminalLock.withLock {
            let current = terminalCount
            if current <= 64 { terminalCount += 1 }
            return current
        }
        if ordinal < 64 {
            var stamped = fields
            stamped["uptimeSeconds"] = ProcessInfo.processInfo.systemUptime
            record(stamped)
        }
        else if ordinal == 64 { record(["kind": "terminalOverflow", "limit": 64]) }
    }
    static func runResult(token: UInt64, code: Int32) {
        terminal(["kind": "nativeRun", "token": token, "errno": code])
    }
    static func sessionStop(_ error: Error?, normalPeerClose: Bool) {
        var fields: [String: Any] = ["kind": "sessionStop", "normalPeerClose": normalPeerClose]
        switch error {
        case nil: fields["category"] = "none"
        case let value as LiveGPUBindingError:
            switch value {
            case .native(_, let code): fields["category"] = "native"; fields["errno"] = code
            case .system(_, let code): fields["category"] = "system"; fields["errno"] = code
            case .protocolViolation(let reason):
                fields["category"] = "protocol"
                fields["reason"] = LiveGPUProtocolDiagnostic.reason(reason)
            case .outputRejected: fields["category"] = "outputRejected"
            }
        case is LiveGPUError: fields["category"] = "transportOrSession"
        default:
            let value = error! as NSError
            switch value.domain {
            case NSPOSIXErrorDomain: fields["category"] = "posix"; fields["errno"] = value.code
            case NSURLErrorDomain: fields["category"] = "url"; fields["code"] = value.code
            case NSCocoaErrorDomain: fields["category"] = "cocoa"; fields["code"] = value.code
            default: fields["category"] = "other"
            }
        }
        terminal(fields)
    }

    enum BindStage: String { case claim, prepare, attach, retireFailedAttach }
    enum OwnerInvalidation: String { case session, ownership, geometry }
    static func bindStage(_ stage: BindStage, code: Int32) {
        terminal(["kind": "surfaceBindStage", "stage": stage.rawValue, "errno": code])
    }
    static func ownerInvalidated(_ reason: OwnerInvalidation) {
        terminal(["kind": "ownerInvalidated", "reason": reason.rawValue])
    }
    /// A lease left view (parked, still bound and presenting) or returned to one.
    static func ownerParked(_ parked: Bool) {
        terminal(["kind": parked ? "ownerParked" : "ownerRestored"])
    }
    static func ownerGeometry(previous: CGSize, server: CGSize?, visible: CGSize?, pending: CGSize?) {
        var fields: [String: Any] = ["kind": "ownerGeometry", "previousWidth": previous.width,
                                   "previousHeight": previous.height]
        for (prefix, size) in [("server", server), ("visible", visible), ("pending", pending)] {
            if let size, size.width.isFinite, size.height.isFinite {
                fields[prefix + "Width"] = size.width
                fields[prefix + "Height"] = size.height
            }
        }
        terminal(fields)
    }
    static func displayClosed(status: Int?, closeCode: Int?, scoped: Bool, error: Error?) {
        var fields: [String: Any] = ["kind": "displayClosed", "scoped": scoped]
        if let status { fields["httpStatus"] = status }
        if let closeCode { fields["closeCode"] = closeCode }
        if let error {
            let value = error as NSError
            switch value.domain {
            case NSURLErrorDomain: fields["category"] = "url"; fields["code"] = value.code
            case NSPOSIXErrorDomain: fields["category"] = "posix"; fields["code"] = value.code
            default: fields["category"] = "other"
            }
        } else { fields["category"] = "none" }
        terminal(fields)
    }
    static func ownerExtent(server: CGSize, view: CGSize) {
        terminal(["kind": "ownerExtent", "drawableWidth": server.width,
                  "drawableHeight": server.height, "viewWidth": view.width, "viewHeight": view.height])
    }
    static func ownerPending(server: CGSize, requested: CGSize?) {
        var fields: [String: Any] = ["kind": "ownerPending", "serverWidth": server.width,
                                   "serverHeight": server.height]
        if let requested {
            fields["requestedWidth"] = requested.width
            fields["requestedHeight"] = requested.height
        }
        terminal(fields)
    }
    static func surfaceConfigured(width: UInt32, height: UInt32, code: Int32) {
        terminal(["kind": "surfaceConfigured", "width": width, "height": height, "errno": code])
    }
    static func swapchainCreated(_ status: LiveGPUSurfaceStatus, count: UInt32) {
        var fields: [String: Any] = ["kind": "swapchainCreated", "errno": status.nativeErrno, "imageCount": count]
        if let result = status.vkResult { fields["vkResult"] = result }
        terminal(fields)
    }
    static func surfaceBind(_ status: LiveGPUSurfaceStatus) {
        var fields: [String: Any] = ["kind": "surfaceBind", "errno": status.nativeErrno]
        if let result = status.vkResult { fields["vkResult"] = result }
        terminal(fields)
    }

    private static func record(_ fields: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: bytes, encoding: .utf8) else { return }
        print("CABOOSE_GPU_MEMORY_AUDIT " + text)
    }
    static func features() {
        guard requested else { return }
        var value = caboose_gpu_memory_features()
        let code = caboose_gpu_runtime_memory_features(&value)
        record(["kind": "features", "errno": code,
                "glDirectMem": value.gl_direct_mem, "virtioGpuNext": value.virtio_gpu_next,
                "disableCoherentEmulation": value.disable_coherent_emulation,
                "ensureCachedCoherent": value.ensure_cached_coherent,
                "allocateDeviceOnly": value.allocate_device_only, "allocateHostMemory": value.allocate_host_memory,
                "systemBlob": value.system_blob, "dedicatedAhbType": value.dedicated_ahb_type,
                "externalBlob": value.external_blob, "virtualQueue": value.virtual_queue,
                "submitWithCommands": value.submit_with_commands, "synchronousProof": value.synchronous_proof,
                "maxSafeHeapSize": value.max_safe_heap_size])
    }
    static func receipts(_ token: UInt64) {
        guard requested else { return }
        var rows = [caboose_gpu_memory_receipt](repeating: .init(), count: 256)
        var count = 0
        let code = rows.withUnsafeMutableBufferPointer {
            caboose_gpu_runtime_memory_receipts(token, $0.baseAddress, $0.count, &count)
        }
        let complete = code == 0 && count >= 0 && count <= rows.count
        record(["kind": "receiptSet", "token": token, "errno": code, "count": count, "complete": complete])
        guard complete else { return }
        for row in rows.prefix(count) {
            record(["kind": "allocation", "token": token, "context": row.context_id,
                    "guestIndex": row.guest_index, "hostIndex": row.host_index,
                    "guestFlags": row.guest_flags, "hostFlags": row.host_flags,
                    "guestFlagsValid": row.guest_flags_valid, "hostFlagsValid": row.host_flags_valid,
                    "externalImport": row.external_import, "hasPNext": row.has_pnext,
                    "guestSize": row.guest_size, "hostSize": row.host_size, "providerResult": row.provider_result])
        }
    }
}
#endif
