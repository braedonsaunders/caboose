// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <cstdint>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <utility>

namespace caboose::gpuv2 {
// Tracks submitted guest GPU work, never presentation-engine retirement.
// Coverage starts disabled: the owner must prove every guest submission path is
// instrumented before enabling it. Any tracking failure permanently disables
// proof. No provider wait is made while this mutex is held.
class GuestGpuCompletion {
public:
    using QueueKey = uint64_t;
    struct Ticket { QueueKey queue = 0; bool active = false; };
    struct IdleSnapshot { QueueKey queue = 0; uint64_t epoch = 0; bool valid = false; bool device = false; };
    class ReleaseGuard {
    public:
        ReleaseGuard() = default;
        ReleaseGuard(ReleaseGuard&&) = default;
        ReleaseGuard& operator=(ReleaseGuard&&) = default;
        bool valid() const { return lock_.owns_lock(); }
    private:
        friend class GuestGpuCompletion;
        explicit ReleaseGuard(std::unique_lock<std::mutex>&& lock) : lock_(std::move(lock)) {}
        std::unique_lock<std::mutex> lock_;
    };
    void enableAuditedCoverage() { std::lock_guard<std::mutex> lock(mutex_); if (!broken_) enabled_ = true; }
    void invalidate() { std::lock_guard<std::mutex> lock(mutex_); broken_ = true; enabled_ = false; }
    // Called while the decoder still holds its object-map lock. A release
    // cannot prove quiescence while a lookup is between that lock and begin().
    void prepareAdmission() { pendingAdmissions_.fetch_add(1); }
    Ticket begin(QueueKey queue, bool prepared = false) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (prepared) pendingAdmissions_.fetch_sub(1);
        if (!enabled_ || broken_ || !queue || epoch_ == std::numeric_limits<uint64_t>::max()) {
            broken_ = true; enabled_ = false; return {};
        }
        try {
            auto& entry = queues_[queue];
            entry.last = ++epoch_; ++entry.active; ++active_;
            return {queue, true};
        } catch (const std::bad_alloc&) { broken_ = true; enabled_ = false; return {}; }
    }
    void end(Ticket& ticket) {
        if (!ticket.active) return;
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = queues_.find(ticket.queue);
        if (it == queues_.end() || !it->second.active || !active_) { broken_ = true; enabled_ = false; }
        else { --it->second.active; --active_; }
        ticket.active = false;
    }
    IdleSnapshot beforeDeviceIdle() {
        std::lock_guard<std::mutex> lock(mutex_);
        return {0, epoch_, enabled_ && !broken_ && !active_ && !pendingAdmissions_.load(), true};
    }
    IdleSnapshot beforeQueueIdle(QueueKey queue) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!enabled_ || broken_ || !queue || pendingAdmissions_.load()) return {};
        try {
            auto& entry = queues_[queue];
            return {queue, entry.last, !entry.active, false};
        } catch (const std::bad_alloc&) { broken_ = true; enabled_ = false; return {}; }
    }
    // success means only the actual decoded provider call returned VK_SUCCESS.
    void afterIdle(const IdleSnapshot& snapshot, bool success) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!success || !snapshot.valid || !enabled_ || broken_ || pendingAdmissions_.load()) return;
        if (snapshot.device) {
            if (active_ || epoch_ != snapshot.epoch) return;
            for (auto& item : queues_) item.second.completed = item.second.last;
        } else {
            auto it = queues_.find(snapshot.queue);
            if (it == queues_.end() || it->second.active || it->second.last != snapshot.epoch) return;
            it->second.completed = it->second.last;
        }
        observed_ = true;
    }
    // The returned guard excludes new tracked submissions through the actual
    // release call. It must never be held while awaiting an idle operation.
    ReleaseGuard tryRelease() {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!enabled_ || broken_ || !observed_ || active_ || pendingAdmissions_.load()) return {};
        for (const auto& item : queues_)
            if (item.second.active || item.second.completed != item.second.last) return {};
        return ReleaseGuard(std::move(lock));
    }
private:
    struct Queue { uint64_t last = 0, completed = 0; uint32_t active = 0; };
    std::mutex mutex_;
    std::atomic<uint64_t> pendingAdmissions_{0};
    std::map<QueueKey, Queue> queues_;
    uint64_t epoch_ = 0;
    uint64_t active_ = 0;
    bool enabled_ = false, broken_ = false, observed_ = false;
};
class GuestGpuWork {
public:
    GuestGpuWork() = default;
    GuestGpuWork(std::shared_ptr<GuestGpuCompletion> tracker, GuestGpuCompletion::QueueKey queue,
                 bool prepared = false)
        : tracker_(std::move(tracker)), ticket_(tracker_ ? tracker_->begin(queue, prepared) : GuestGpuCompletion::Ticket{}) {}
    GuestGpuWork(const GuestGpuWork&) = delete;
    GuestGpuWork& operator=(const GuestGpuWork&) = delete;
    GuestGpuWork(GuestGpuWork&& other) noexcept
        : tracker_(std::move(other.tracker_)), ticket_(other.ticket_) { other.ticket_.active = false; }
    void invalidate() { if (tracker_) tracker_->invalidate(); }
    ~GuestGpuWork() { if (tracker_) tracker_->end(ticket_); }
private:
    std::shared_ptr<GuestGpuCompletion> tracker_;
    GuestGpuCompletion::Ticket ticket_{};
};
}
