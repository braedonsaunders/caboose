// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "memory_audit.h"
#include <cassert>
using caboose::gpuv2::MemoryAuditRing;
int main() {
    MemoryAuditRing ring;
    caboose_gpu_memory_receipt a{}; a.context_id = 11; a.guest_index = 3; a.host_index = 7; a.provider_result = -4;
    caboose_gpu_memory_receipt b{}; b.context_id = 12; b.guest_index = 2; b.host_index = 5;
    ring.record(a); ring.record(b);
    size_t count = 0;
    assert(!ring.read(11, nullptr, 0, &count) && count == 1);
    caboose_gpu_memory_receipt out[2]{};
    assert(ring.read(11, out, 2, &count) && count == 1);
    assert(out[0].context_id == 11 && out[0].guest_index == 3 && out[0].host_index == 7 && out[0].provider_result == -4);
    assert(ring.read(12, out, 2, &count) && count == 1 && out[0].host_index == 5);
    for (size_t i = 2; i < MemoryAuditRing::kCapacity; ++i) ring.record(b);
    ring.record(a);
    assert(!ring.read(11, out, 2, &count)); // overflow is explicit, never partial success
}
