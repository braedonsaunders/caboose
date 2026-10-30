// SPDX-License-Identifier: AGPL-3.0-or-later
#include "publication.h"
#include <algorithm>
#include <cstring>
#include <limits>
#include <new>

namespace caboose::coherent {
bool Publisher::attach(uint64_t id, uint8_t* storage, size_t size) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (lost_ || !storage || !size || id <= lastAllocation_) return false;
    try { allocations_.emplace(id, Mapping{storage, size}); }
    catch (const std::bad_alloc&) { lost_ = true; return false; }
    lastAllocation_ = id;
    return true;
}
void Publisher::detach(uint64_t id) {
    std::lock_guard<std::mutex> lock(mutex_);
    allocations_.erase(id);
}
void Publisher::lose() {
    std::lock_guard<std::mutex> lock(mutex_);
    lost_ = true;
}
Result Publisher::publish(const Completion& c) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto fail = [&] { lost_ = true; return Result::lost; };
    if (lost_) return Result::lost;
    if (!c.cut.queue || !c.cut.serial) return fail();
    // Allocate bookkeeping before touching any application bytes.
    std::map<uint64_t, uint64_t>::iterator queue;
    try { queue = published_.try_emplace(c.cut.queue, 0).first; }
    catch (const std::bad_alloc&) { return fail(); }
    if (c.cut.serial <= queue->second) return fail(); // Replay is not harmless:
    // the CPU may have overwritten these bytes since the earlier publication.
    if (queue->second == std::numeric_limits<uint64_t>::max()) return fail();
    if (c.cut.serial != queue->second + 1) return Result::pending;
    for (const auto& d : c.dependencies) {
        if (!d.queue || !d.serial || (d.queue == c.cut.queue && d.serial >= c.cut.serial))
            return fail();
        auto it = published_.find(d.queue);
        if (it == published_.end() || it->second < d.serial) return Result::pending;
    }
    // Sort references, not payloads: validation stays O(n log n) for fragmented
    // journals. All scratch allocation precedes the first application write.
    std::vector<const Write*> ordered;
    try {
        ordered.reserve(c.writes.size());
        for (const auto& w : c.writes) ordered.push_back(&w);
    } catch (const std::bad_alloc&) { return fail(); }
    std::sort(ordered.begin(), ordered.end(), [](const Write* a, const Write* b) {
        return a->allocation < b->allocation ||
            (a->allocation == b->allocation && a->offset < b->offset);
    });
    // Validate the complete transaction before publishing its first byte.
    const Write* previous = nullptr;
    for (const auto* entry : ordered) {
        const auto& w = *entry;
        auto it = allocations_.find(w.allocation);
        if (it == allocations_.end() || w.bytes.empty() ||
            w.offset > it->second.size || w.bytes.size() > it->second.size - w.offset)
            return fail();
        if (previous && previous->allocation == w.allocation &&
            w.offset < previous->offset + previous->bytes.size()) return fail();
        previous = entry;
    }
    for (const auto& w : c.writes) {
        auto& mapping = allocations_.find(w.allocation)->second;
        // Never round to a page, word, or nonCoherentAtomSize. Valid application
        // host accesses may concurrently touch adjacent bytes. memcpy only owns
        // the exact destination interval under the C++ memory model.
        std::memcpy(mapping.bytes + w.offset, w.bytes.data(), w.bytes.size());
    }
    queue->second = c.cut.serial;
    return Result::published;
}
}
