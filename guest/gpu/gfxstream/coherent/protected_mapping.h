// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <cstddef>
#include <mutex>

namespace caboose::coherent {
// Linux anonymous mapping with a short, whole-mapping CPU-store exclusion cut.
// This is NOT a GPU ownership lock. Never wait for GPU/transport while Frozen.
// No virtual-address aliases or externally imported memory are supported.
class ProtectedMapping {
public:
    explicit ProtectedMapping(size_t bytes);
    ~ProtectedMapping();
    ProtectedMapping(const ProtectedMapping&) = delete;
    ProtectedMapping& operator=(const ProtectedMapping&) = delete;
    void* data() const { return data_; }
    size_t size() const { return size_; }
    bool lost();
    class Frozen {
    public:
        explicit Frozen(ProtectedMapping& mapping);
        ~Frozen();
        Frozen(const Frozen&) = delete;
        Frozen& operator=(const Frozen&) = delete;
    private:
        ProtectedMapping& mapping_;
        std::unique_lock<std::mutex> lock_;
    };
private:
    void protect(bool enabled);
    void* data_ = nullptr;
    size_t size_ = 0;
    int fd_ = -1;
    std::mutex mutex_;
};
}
