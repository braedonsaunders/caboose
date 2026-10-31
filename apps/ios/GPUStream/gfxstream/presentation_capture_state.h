// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <cstdint>
#include <vector>

namespace caboose::gpuv2 {
// Ownership of a presented-picture capture ring. A slot is reserved for a present before its
// copy is recorded, becomes lent to the phone's scroll compositor once the copy fence has
// actually signaled, and is free again only when the compositor releases it. Tokens carry
// the ring generation, so a release for a ring that was replaced is ignored. A present finds
// no slot while every slot is written or lent; it then presents without a capture.
// Caller serializes all access. This tracks ownership; it performs no GPU work.
class PresentationCaptureState {
public:
    // Replaces the ring. Slots lent from the old generation stay with their borrower and
    // cannot be released into the new one.
    void reset(uint32_t count) {
        slots_.assign(count, Slot{});
        ++generation_;
        if (!generation_) generation_ = 1;
    }
    uint32_t count() const { return static_cast<uint32_t>(slots_.size()); }
    // A free slot for present `serial`, or -1.
    int reserve(uint64_t serial) {
        if (!serial) return -1;
        for (const auto& slot : slots_) if (slot.state == Writing && slot.serial == serial) return -1;
        for (uint32_t i = 0; i < slots_.size(); ++i) {
            if (slots_[i].state != Free) continue;
            slots_[i] = Slot{Writing, serial};
            return static_cast<int>(i);
        }
        return -1;
    }
    // The copy for `serial` completed: its slot is lent. False when no slot was written for it.
    bool complete(uint64_t serial, uint32_t* token) {
        for (uint32_t i = 0; i < slots_.size(); ++i) {
            if (slots_[i].state != Writing || slots_[i].serial != serial) continue;
            slots_[i].state = Lent;
            if (token) *token = this->token(i);
            return true;
        }
        return false;
    }
    // The copy for `serial` was never submitted: its slot is free again.
    bool abort(uint64_t serial) {
        for (auto& slot : slots_) {
            if (slot.state != Writing || slot.serial != serial) continue;
            slot = Slot{};
            return true;
        }
        return false;
    }
    // The copy's outcome is unknown (device loss, an unsignaled fence): never reuse its slot.
    void quarantine(uint64_t serial) {
        for (auto& slot : slots_) if (slot.state == Writing && slot.serial == serial) slot.state = Quarantined;
    }
    bool release(uint32_t token) {
        const uint32_t index = token & 0xff;
        if ((token >> 8) != (generation_ & 0xffffff) || index >= slots_.size() || slots_[index].state != Lent) return false;
        slots_[index] = Slot{};
        return true;
    }
    // No copy is in flight into the ring, so its images may be destroyed.
    bool idle() const {
        for (const auto& slot : slots_) if (slot.state == Writing || slot.state == Quarantined) return false;
        return true;
    }
    uint32_t token(uint32_t index) const { return ((generation_ & 0xffffff) << 8) | (index & 0xff); }

private:
    enum State : uint8_t { Free, Writing, Lent, Quarantined };
    struct Slot { State state = Free; uint64_t serial = 0; };
    std::vector<Slot> slots_;
    uint32_t generation_ = 0;
};
}
