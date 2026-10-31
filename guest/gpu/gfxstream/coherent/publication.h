// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <vector>

namespace caboose::coherent {
// Internal interface, not a wire format. One Publisher per logical device.
struct Cut { uint64_t queue, serial; };
struct Write {
    uint64_t allocation; // Monotonic identity; never a reusable Vulkan handle.
    size_t offset;
    std::vector<uint8_t> bytes; // Exact store footprint, including same-value stores.
};
struct Completion {
    Cut cut;
    std::vector<Cut> dependencies;
    std::vector<Write> writes; // Nonoverlapping, final bytes at this cut.
};
enum class Result { published, pending, lost };

class Publisher {
public:
    // Storage is owned by the caller, retained until detach returns. All aliases
    // resolve to this allocation identity and allocation-relative offsets.
    bool attach(uint64_t allocation, uint8_t* storage, size_t size);
    void detach(uint64_t allocation);
    // Caller exposes successful fence/event/semaphore observation ONLY after
    // published. A NOT_READY/TIMEOUT is not a completion and never calls this.
    // Source must provide exact store coverage and dependency edges. This class
    // cannot derive either from descriptor ranges or final allocation snapshots.
    Result publish(const Completion& completion);
    void lose();
private:
    struct Mapping { uint8_t* bytes; size_t size; };
    std::mutex mutex_;
    bool lost_ = false;
    uint64_t lastAllocation_ = 0;
    std::map<uint64_t, Mapping> allocations_;
    std::map<uint64_t, uint64_t> published_;
};
}
