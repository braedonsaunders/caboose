#if DEBUG && canImport(CabooseGPUMemoryAudit)
import Foundation
import CabooseGPUMemoryAudit

/// Explicit diagnostic package + launch opt-in. Only feature flags, allocation
/// indices/sizes and provider results are recorded; never memory contents or credentials.
enum LiveGPUMemoryAudit {
    private static let requested = ProcessInfo.processInfo.environment["CABOOSE_PRIVATE_GPU_MEMORY_AUDIT"] == "1"
    static func enable() -> Int32 { caboose_gpu_runtime_enable_memory_audit() }

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
