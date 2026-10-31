// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>
#include <functional>
#include <iterator>
#include <mutex>
#include <unordered_map>

namespace caboose::memory {

// Set by the resource tracker around an encoder vkAllocateMemory call that may return
// before the device answers: the device registers the allocation under the handle the
// guest assigned and its reply is read later.
inline thread_local bool asyncAllocation = false;

// Decides which device-memory allocations can skip the round trip. An allocation the
// device refuses after the guest has returned success is device loss, so only plain
// allocations that leave ample room in their heap are sent without waiting: the guest
// tracks every allocation it made on each heap, and an allocation that would take a
// heap past `numerator/denominator` of its size waits for the device's answer, where
// a real VK_ERROR_OUT_OF_DEVICE_MEMORY still reaches the application.
class AsyncAllocationBudget {
public:
    static constexpr uint64_t kNumerator = 1, kDenominator = 2;

    // Reserves `size` bytes of `heap` on `device` for an allocation sent without waiting.
    // False means the caller must allocate synchronously.
    bool reserve(uint64_t device, uint32_t heap, uint64_t heapSize, uint64_t size) {
        if (!size || !heapSize) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        uint64_t& used = committed_[key(device, heap)];
        const uint64_t limit = heapSize / kDenominator * kNumerator;
        if (used > limit || size > limit - used) return false;
        used += size;
        return true;
    }
    // Records an allocation the device answered (synchronously), so later decisions see it.
    void commit(uint64_t device, uint32_t heap, uint64_t size) {
        std::lock_guard<std::mutex> lock(mutex_);
        uint64_t& used = committed_[key(device, heap)];
        used = size > UINT64_MAX - used ? UINT64_MAX : used + size;
    }
    // Ties a reserved or committed allocation to its handle, so freeing it releases its bytes.
    void track(uint64_t memory, uint64_t device, uint32_t heap, uint64_t size) {
        if (!memory) return;
        std::lock_guard<std::mutex> lock(mutex_);
        allocations_[memory] = {device, heap, size};
    }
    // Returns a reservation whose allocation was never handed to the application.
    void cancel(uint64_t device, uint32_t heap, uint64_t size) {
        std::lock_guard<std::mutex> lock(mutex_);
        release(key(device, heap), size);
    }
    void freed(uint64_t memory) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = allocations_.find(memory);
        if (it == allocations_.end()) return;
        release(key(it->second.device, it->second.heap), it->second.size);
        allocations_.erase(it);
    }
    void deviceDestroyed(uint64_t device) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto it = allocations_.begin(); it != allocations_.end();)
            it = it->second.device == device ? allocations_.erase(it) : std::next(it);
        for (auto it = committed_.begin(); it != committed_.end();)
            it = it->first.device == device ? committed_.erase(it) : std::next(it);
    }
    uint64_t committed(uint64_t device, uint32_t heap) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = committed_.find(key(device, heap));
        return it == committed_.end() ? 0 : it->second;
    }

private:
    struct Key {
        uint64_t device;
        uint32_t heap;
        bool operator==(const Key& other) const { return device == other.device && heap == other.heap; }
    };
    struct KeyHash {
        size_t operator()(const Key& k) const { return std::hash<uint64_t>()(k.device * 31 + k.heap); }
    };
    struct Allocation { uint64_t device; uint32_t heap; uint64_t size; };
    static Key key(uint64_t device, uint32_t heap) { return {device, heap}; }
    void release(const Key& k, uint64_t size) {
        auto it = committed_.find(k);
        if (it == committed_.end()) return;
        it->second = it->second > size ? it->second - size : 0;
    }
    std::mutex mutex_;
    std::unordered_map<Key, uint64_t, KeyHash> committed_;
    std::unordered_map<uint64_t, Allocation> allocations_;
};

inline AsyncAllocationBudget asyncAllocationBudget;

}  // namespace caboose::memory
