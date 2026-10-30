// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#ifndef CABOOSE_GPU_MEMORY_AUDIT_H
#define CABOOSE_GPU_MEMORY_AUDIT_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Diagnostic-only data. Indices refer to the actual allocation call; no pointers
// or memory content are recorded. provider_result is the actual vkAllocateMemory
// return, which can differ from a later decoder-side allocation result.
typedef struct caboose_gpu_memory_receipt {
    uint32_t context_id;
    uint32_t guest_index;
    uint32_t host_index;
    uint32_t guest_flags;
    uint32_t host_flags;
    uint32_t guest_flags_valid;
    uint32_t host_flags_valid;
    uint32_t external_import; // emulated ColorBuffer/Buffer import path
    uint32_t has_pnext;       // nonzero if guest allocation supplied extensions
    uint64_t guest_size;
    uint64_t host_size;
    int32_t provider_result;
} caboose_gpu_memory_receipt;

typedef struct caboose_gpu_memory_features {
    uint32_t gl_direct_mem, virtio_gpu_next, disable_coherent_emulation;
    uint32_t ensure_cached_coherent, allocate_device_only, allocate_host_memory;
    uint32_t system_blob, dedicated_ahb_type, external_blob;
    uint32_t virtual_queue, submit_with_commands, synchronous_proof;
    uint64_t max_safe_heap_size;
} caboose_gpu_memory_features;
#ifdef CABOOSE_GPU_MEMORY_AUDIT
// Set before the first v4 runtime start; compiled only in a diagnostic build.
int caboose_gpu_runtime_enable_memory_audit(void);
int caboose_gpu_runtime_memory_features(caboose_gpu_memory_features* out);
// Read-only snapshot for an existing process token. EOVERFLOW means the fixed
// audit ring or caller buffer was too small; no partial receipt set is returned.
int caboose_gpu_runtime_memory_receipts(uint64_t token, caboose_gpu_memory_receipt* out,
                                       size_t capacity, size_t* count);
#endif
#ifdef __cplusplus
}
#include <array>
#include <mutex>
namespace caboose::gpuv2 {
// Fixed global capacity; reads select exactly one upstream context. Overflow is
// explicit and makes the diagnostic snapshot incomplete, never a silent pass.
class MemoryAuditRing {
public:
    static constexpr size_t kCapacity = 256;
    void record(const caboose_gpu_memory_receipt& receipt) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (size_ == kCapacity) { overflow_ = true; return; }
        entries_[size_++] = receipt;
    }
    bool read(uint32_t context, caboose_gpu_memory_receipt* out, size_t capacity, size_t* count) {
        std::lock_guard<std::mutex> lock(mutex_);
        size_t needed = 0;
        for (size_t i = 0; i < size_; ++i) if (entries_[i].context_id == context) ++needed;
        *count = needed;
        if (overflow_ || needed > capacity || (needed && !out)) return false;
        size_t index = 0;
        for (size_t i = 0; i < size_; ++i) if (entries_[i].context_id == context) out[index++] = entries_[i];
        return true;
    }
private:
    std::mutex mutex_;
    std::array<caboose_gpu_memory_receipt, kCapacity> entries_{};
    size_t size_ = 0;
    bool overflow_ = false;
};
}
#endif
#endif // CABOOSE_GPU_MEMORY_AUDIT_H
