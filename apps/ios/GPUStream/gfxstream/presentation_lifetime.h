// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <condition_variable>
#include <cstddef>
#include <memory>
#include <mutex>
#include <utility>
#include <vector>

namespace caboose::gpuv2 {
// A gate belongs to one tracked Vulkan object. The owning decoder-state mutex
// serializes tryAcquire() with close(); release and drain need no decoder lock.
class PresentationLifetime {
public:
    bool tryAcquire() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closed_ || mutating_) return false;
        ++active_;
        return true;
    }
    void release() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (--active_ == 0) drained_.notify_all();
    }
    void close() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = true;
    }
    bool tryMutation() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closed_ || active_) return false;
        mutating_ = true;
        ++active_;
        return true;
    }
    void endMutation() {
        std::lock_guard<std::mutex> lock(mutex_);
        mutating_ = false;
        if (--active_ == 0) drained_.notify_all();
    }
    void wait() {
        std::unique_lock<std::mutex> lock(mutex_);
        drained_.wait(lock, [this] { return active_ == 0; });
    }
private:
    std::mutex mutex_;
    std::condition_variable drained_;
    size_t active_ = 0;
    bool closed_ = false;
    bool mutating_ = false;
};

// Noncopyable; ownership may be transferred between threads. A submitted GPU operation must
// retain its lease until actual completion or terminal device loss.
class PresentationLease {
public:
    PresentationLease() = default;
    PresentationLease(const PresentationLease&) = delete;
    PresentationLease& operator=(const PresentationLease&) = delete;
    ~PresentationLease() { for (auto& gate : gates_) gate->release(); }
    bool acquire(const std::shared_ptr<PresentationLifetime>& gate) {
        if (!gate || !gate->tryAcquire()) return false;
        try { gates_.push_back(gate); }
        catch (...) { gate->release(); throw; }
        return true;
    }
private:
    std::vector<std::shared_ptr<PresentationLifetime>> gates_;
};

// Used while a real bind call is in flight, including its state update. An
// existing presenter lease or another mutation rejects admission immediately.
class PresentationMutation {
public:
    PresentationMutation() = default;
    PresentationMutation(const PresentationMutation&) = delete;
    PresentationMutation& operator=(const PresentationMutation&) = delete;
    ~PresentationMutation() { for (auto& gate : gates_) gate->endMutation(); }
    bool acquire(const std::shared_ptr<PresentationLifetime>& gate) {
        for (const auto& held : gates_) if (held == gate) return true;
        if (!gate || !gate->tryMutation()) return false;
        try { gates_.push_back(gate); }
        catch (...) { gate->endMutation(); throw; }
        return true;
    }
private:
    std::vector<std::shared_ptr<PresentationLifetime>> gates_;
};
}
