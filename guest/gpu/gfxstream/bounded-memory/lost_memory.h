#pragma once
// Memory allocated while the executor is lost (docs/gpu-live.md, Executor generations).
//
// A device whose executor is gone still answers its application the way a lost Vulkan device
// does: objects are made (with guest handles that never reach an executor), and memory is
// allocated and can be mapped, flushed and invalidated, so an application that is mid-frame
// when the executor leaves (Zink uploading a texture) gets valid results instead of failures it
// does not survive. Such memory is local, zeroed and holds nothing; it is freed with its handle.
// Each allocation is at most kMaxBytes and all of them at most kTotalBytes: a larger one is
// refused with VK_ERROR_OUT_OF_DEVICE_MEMORY, which an allocation may always return.

#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <unordered_map>

namespace caboose::memory {

class LostMemory {
public:
    static constexpr uint64_t kMaxBytes = 64ull << 20, kTotalBytes = 256ull << 20;

    // Whether an allocation of `size` bytes for `handle` was made.
    bool allocated(uint64_t handle, uint64_t size) {
        if (!handle || !size || size > kMaxBytes) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (total_ + size > kTotalBytes || blocks_.count(handle)) return false;
        void* bytes = std::calloc(1, size_t(size));
        if (!bytes) return false;
        blocks_[handle] = Block{static_cast<uint8_t*>(bytes), size};
        total_ += size;
        return true;
    }
    // The address of `offset` in `handle`'s memory, or null for memory made while connected.
    void* map(uint64_t handle, uint64_t offset) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = blocks_.find(handle);
        if (found == blocks_.end() || offset >= found->second.size) return nullptr;
        return found->second.bytes + offset;
    }
    bool contains(uint64_t handle) {
        std::lock_guard<std::mutex> lock(mutex_);
        return blocks_.count(handle) != 0;
    }
    void freed(uint64_t handle) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = blocks_.find(handle);
        if (found == blocks_.end()) return;
        total_ -= found->second.size;
        std::free(found->second.bytes);
        blocks_.erase(found);
    }
    uint64_t bytes() {
        std::lock_guard<std::mutex> lock(mutex_);
        return total_;
    }

private:
    struct Block {
        uint8_t* bytes;
        uint64_t size;
    };
    std::mutex mutex_;
    std::unordered_map<uint64_t, Block> blocks_;
    uint64_t total_ = 0;
};

// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline LostMemory& lostMemory = *new LostMemory;

}  // namespace caboose::memory
