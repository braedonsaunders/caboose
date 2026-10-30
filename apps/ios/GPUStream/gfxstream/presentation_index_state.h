// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstdint>
#include <map>
#include <vector>

namespace caboose::gpuv2 {
// Caller serializes all access and changes state only after the corresponding
// real provider operation/fence. This tracks ownership; it performs no GPU work.
class PresentationIndexState {
public:
    explicit PresentationIndexState(uint32_t count) : indices_(count) {}
    bool markAcquired(uint32_t index) {
        if (index >= indices_.size() || indices_[index].acquired || indices_[index].quarantined) return false;
        indices_[index].acquired = true;
        return true;
    }
    bool sourceReusable(uint32_t index) const {
        if (index >= indices_.size() || !indices_[index].acquired || indices_[index].quarantined) return false;
        for (const auto& entry : frames_)
            if (entry.second.index == index && !entry.second.sourceReleased) return false;
        return true;
    }
    // Reserve bookkeeping before any queue submission so allocation failure
    // cannot lose an already submitted operation.
    bool beginPresent(uint32_t index, uint64_t serial) {
        if (!sourceReusable(index) || indices_[index].pending || !serial || serial <= lastSerial_) return false;
        auto inserted = frames_.emplace(serial, Frame{index, false, false, false, false});
        if (!inserted.second) return false;
        indices_[index].pending = true;
        lastSerial_ = serial;
        return true;
    }
    bool markCopySubmitted(uint64_t serial) {
        auto it = frames_.find(serial);
        if (it == frames_.end() || it->second.copySubmitted) return false;
        it->second.copySubmitted = true;
        return true;
    }
    // Call only after real queuePresent accepts. Fence records survive reacquire.
    bool markPresented(uint64_t serial) {
        auto it = frames_.find(serial);
        if (it == frames_.end() || !it->second.copySubmitted || it->second.queued) return false;
        auto& index = indices_[it->second.index];
        if (!index.acquired || !index.pending || index.quarantined) return false;
        index.pending = false; index.acquired = false; it->second.queued = true;
        return true;
    }
    // Only if no queue submission or wait consumption was attempted.
    bool abortBeforeSubmit(uint64_t serial) {
        auto it = frames_.find(serial);
        if (it == frames_.end() || it->second.copySubmitted || it->second.queued) return false;
        indices_[it->second.index].pending = false;
        frames_.erase(it);
        return true;
    }
    bool markSourceReleased(uint64_t serial) {
        auto it = frames_.find(serial);
        if (it == frames_.end() || !it->second.copySubmitted || it->second.sourceReleased) return false;
        it->second.sourceReleased = true;
        return true;
    }
    bool markPresentRetired(uint64_t serial) {
        auto it = frames_.find(serial);
        if (it == frames_.end() || !it->second.queued || it->second.presentRetired) return false;
        it->second.presentRetired = true;
        return true;
    }
    bool forgetRetired(uint64_t serial) {
        auto it = frames_.find(serial);
        if (it == frames_.end() || !it->second.sourceReleased || !it->second.presentRetired) return false;
        frames_.erase(it);
        return true;
    }
    // Only after actual maintenance1 release of an acquired unused image.
    bool markUnusedReleased(uint32_t index) {
        if (!sourceReusable(index) || indices_[index].pending) return false;
        indices_[index].acquired = false;
        return true;
    }
    void quarantine(uint32_t index) { if (index < indices_.size()) indices_[index].quarantined = true; }
    bool mayRetire() const {
        if (!frames_.empty()) return false;
        for (const auto& index : indices_) if (index.acquired || index.quarantined) return false;
        return true;
    }
private:
    struct Index { bool acquired = false; bool quarantined = false; bool pending = false; };
    struct Frame { uint32_t index; bool sourceReleased; bool presentRetired; bool queued; bool copySubmitted; };
    std::vector<Index> indices_;
    std::map<uint64_t, Frame> frames_;
    uint64_t lastSerial_ = 0;
};
}
