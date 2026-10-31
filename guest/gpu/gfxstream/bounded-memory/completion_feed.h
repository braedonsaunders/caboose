// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <utility>
#include <vector>

// Completion feedback. With hello feature 0x200 the process opens a second device stream
// whose only command is COMPLETION_FEED; after every queue submission that signals a
// fence or timeline semaphore it sends COMPLETION_WATCH(queue, serial) on its device
// stream, and the phone answers on the feed stream with the serial once all work
// submitted to that queue before the watch has completed. Fence and timeline state is
// then known in the guest: status queries and waits never make a round trip.
namespace caboose::completion {

// Wire, little-endian. Both commands use the ordinary 8-byte gfxstream packet header
// (opcode, total packet size); neither has a reply on its own stream.
inline constexpr uint32_t kFeedOpcode = 0x4342FE01;   // payload: version u32 = 1, reserved u32 = 0
inline constexpr uint32_t kWatchOpcode = 0x4342FE02;  // payload: boxed queue u64, serial u64
inline constexpr uint32_t kFeedVersion = 1;
inline constexpr uint32_t kFeedPacketSize = 16;
inline constexpr uint32_t kWatchPacketSize = 24;
// A feed record: serial u64, status i32, reserved u32 = 0.
inline constexpr size_t kRecordSize = 16;
// Record status: the work completed; the device was lost; or the phone cannot watch
// that queue (a deferred or shared queue), so its fences must be asked about directly.
inline constexpr int32_t kCompleted = 0;
inline constexpr int32_t kDeviceLost = -4;  // VK_ERROR_DEVICE_LOST
inline constexpr int32_t kUnwatched = 1;    // VK_NOT_READY

inline void encodeWatch(uint8_t out[kWatchPacketSize], uint64_t boxedQueue, uint64_t serial) {
    const uint32_t opcode = kWatchOpcode, size = kWatchPacketSize;
    std::memcpy(out, &opcode, 4);
    std::memcpy(out + 4, &size, 4);
    std::memcpy(out + 8, &boxedQueue, 8);
    std::memcpy(out + 16, &serial, 8);
}
inline void encodeFeed(uint8_t out[kFeedPacketSize]) {
    const uint32_t opcode = kFeedOpcode, size = kFeedPacketSize, version = kFeedVersion, reserved = 0;
    std::memcpy(out, &opcode, 4);
    std::memcpy(out + 4, &size, 4);
    std::memcpy(out + 8, &version, 4);
    std::memcpy(out + 12, &reserved, 4);
}

// The guest's view of every fence and timeline semaphore whose signal operations it has
// seen. An object stays "tracked" only while each of its signal operations is either a
// watched submission or done by the guest itself; any other (an imported payload, a
// presentation-engine acquire, a submission the phone cannot watch) makes it untracked
// until a reset, and the caller then asks the device as before.
class Tracker {
public:
    enum class Fence { Unsignaled, Signaled, Pending, Untracked };
    using Clock = std::chrono::steady_clock;

    // --- Fences -----------------------------------------------------------------------
    void fenceCreated(uint64_t fence, bool signaled) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& state = fences_[fence];
        state = FenceState{};
        state.state = signaled ? Fence::Signaled : Fence::Unsignaled;
    }
    void fenceDestroyed(uint64_t fence) {
        std::lock_guard<std::mutex> lock(mutex_);
        fences_.erase(fence);
    }
    void fenceReset(uint64_t fence) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& state = fences_[fence];
        state.state = Fence::Unsignaled;
        state.serial = 0;
    }
    // A signal operation the guest cannot follow.
    void fenceUntracked(uint64_t fence) {
        if (!fence) return;
        std::lock_guard<std::mutex> lock(mutex_);
        auto& state = fences_[fence];
        state.state = Fence::Untracked;
        state.serial = 0;
    }
    Fence fence(uint64_t fence) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = fences_.find(fence);
        return it == fences_.end() ? Fence::Untracked : it->second.state;
    }
    // A submission's signal operations, before it is sent. Returns the serial to watch.
    uint64_t submitted(uint64_t fence, const std::vector<std::pair<uint64_t, uint64_t>>& timelineSignals) {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t serial = ++lastSerial_;
        Watch watch;
        if (fence) {
            auto& state = fences_[fence];
            state.state = Fence::Pending;
            state.serial = serial;
            watch.fence = fence;
        }
        for (const auto& [semaphore, value] : timelineSignals) {
            auto it = semaphores_.find(semaphore);
            if (it == semaphores_.end() || !it->second.tracked) continue;
            watch.signals.push_back({semaphore, value});
            it->second.pending = std::max(it->second.pending, value);
        }
        watches_.emplace(serial, std::move(watch));
        return serial;
    }
    // A submission whose watch could not be sent: its objects are untracked.
    void unwatched(uint64_t serial) { complete(serial, kUnwatched); }

    // --- Timeline semaphores ------------------------------------------------------------
    void timelineCreated(uint64_t semaphore, uint64_t initialValue) {
        std::lock_guard<std::mutex> lock(mutex_);
        semaphores_[semaphore] = SemaphoreState{true, initialValue, initialValue};
    }
    void semaphoreDestroyed(uint64_t semaphore) {
        std::lock_guard<std::mutex> lock(mutex_);
        semaphores_.erase(semaphore);
    }
    void semaphoreUntracked(uint64_t semaphore) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        if (it != semaphores_.end()) it->second.tracked = false;
    }
    // vkSignalSemaphore: the host sets the value directly.
    void timelineSignaledByHost(uint64_t semaphore, uint64_t value) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        if (it == semaphores_.end() || !it->second.tracked) return;
        it->second.value = std::max(it->second.value, value);
        changed_.notify_all();
    }
    // The completed value of a tracked timeline; false when untracked.
    bool timelineValue(uint64_t semaphore, uint64_t* value) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        if (it == semaphores_.end() || !it->second.tracked) return false;
        *value = it->second.value;
        return true;
    }

    // --- Feed ---------------------------------------------------------------------------
    // A record from the feed stream. Unknown serials (already superseded) are ignored.
    void complete(uint64_t serial, int32_t status) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = watches_.find(serial);
        if (it == watches_.end()) return;
        Watch watch = std::move(it->second);
        watches_.erase(it);
        if (status == kDeviceLost) {
            lost_ = true;
        } else if (watch.fence) {
            auto fence = fences_.find(watch.fence);
            if (fence != fences_.end() && fence->second.state == Fence::Pending &&
                fence->second.serial == serial) {
                fence->second.state = status == kCompleted ? Fence::Signaled : Fence::Untracked;
                fence->second.serial = 0;
            }
        }
        for (const auto& [semaphore, value] : watch.signals) {
            auto state = semaphores_.find(semaphore);
            if (state == semaphores_.end()) continue;
            if (status == kCompleted) state->second.value = std::max(state->second.value, value);
            else state->second.tracked = false;
        }
        changed_.notify_all();
    }
    // The feed ended: nothing pending will be reported any more.
    void feedClosed() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = true;
        changed_.notify_all();
    }
    bool deviceLost() {
        std::lock_guard<std::mutex> lock(mutex_);
        return lost_;
    }

    // --- Queries and waits ---------------------------------------------------------------
    enum class Answer { Satisfied, NotYet, DeviceLost, AskDevice };
    // Fence status without waiting.
    Answer fencesSignaled(const uint64_t* fences, uint32_t count, bool all) {
        std::lock_guard<std::mutex> lock(mutex_);
        return fencesLocked(fences, count, all);
    }
    // Waits until the fences are signaled (all, or any) or `deadline` passes.
    Answer waitFences(const uint64_t* fences, uint32_t count, bool all, Clock::time_point deadline) {
        std::unique_lock<std::mutex> lock(mutex_);
        for (;;) {
            Answer answer = fencesLocked(fences, count, all);
            if (answer != Answer::NotYet) return answer;
            if (closed_) return Answer::AskDevice;
            if (changed_.wait_until(lock, deadline) == std::cv_status::timeout) {
                answer = fencesLocked(fences, count, all);
                return answer == Answer::NotYet && closed_ ? Answer::AskDevice : answer;
            }
        }
    }
    // Waits until the timelines reach their values (all, or any) or `deadline` passes.
    Answer waitTimelines(const uint64_t* semaphores, const uint64_t* values, uint32_t count, bool all,
                         Clock::time_point deadline) {
        std::unique_lock<std::mutex> lock(mutex_);
        for (;;) {
            Answer answer = timelinesLocked(semaphores, values, count, all);
            if (answer != Answer::NotYet) return answer;
            if (closed_) return Answer::AskDevice;
            if (changed_.wait_until(lock, deadline) == std::cv_status::timeout) {
                answer = timelinesLocked(semaphores, values, count, all);
                return answer == Answer::NotYet && closed_ ? Answer::AskDevice : answer;
            }
        }
    }
    size_t pendingWatches() {
        std::lock_guard<std::mutex> lock(mutex_);
        return watches_.size();
    }

private:
    struct FenceState { Fence state = Fence::Unsignaled; uint64_t serial = 0; };
    struct SemaphoreState { bool tracked = false; uint64_t value = 0; uint64_t pending = 0; };
    struct Watch { uint64_t fence = 0; std::vector<std::pair<uint64_t, uint64_t>> signals; };

    Answer fencesLocked(const uint64_t* fences, uint32_t count, bool all) {
        if (lost_) return Answer::DeviceLost;
        uint32_t signaled = 0;
        for (uint32_t i = 0; i < count; ++i) {
            auto it = fences_.find(fences[i]);
            if (it == fences_.end() || it->second.state == Fence::Untracked) return Answer::AskDevice;
            if (it->second.state == Fence::Signaled) ++signaled;
        }
        // An unsignaled fence with no pending submission can only be signaled by a later
        // submission, so waiting for it here is exactly what the application asked for.
        return (all ? signaled == count : signaled > 0) ? Answer::Satisfied : Answer::NotYet;
    }
    Answer timelinesLocked(const uint64_t* semaphores, const uint64_t* values, uint32_t count, bool all) {
        if (lost_) return Answer::DeviceLost;
        uint32_t reached = 0;
        for (uint32_t i = 0; i < count; ++i) {
            auto it = semaphores_.find(semaphores[i]);
            if (it == semaphores_.end() || !it->second.tracked) return Answer::AskDevice;
            if (it->second.value >= values[i]) ++reached;
        }
        return (all ? reached == count : reached > 0) ? Answer::Satisfied : Answer::NotYet;
    }

    std::mutex mutex_;
    std::condition_variable changed_;
    std::unordered_map<uint64_t, FenceState> fences_;
    std::unordered_map<uint64_t, SemaphoreState> semaphores_;
    std::unordered_map<uint64_t, Watch> watches_;
    uint64_t lastSerial_ = 0;
    bool lost_ = false;
    bool closed_ = false;
};

// Set while this process's completion feed is running.
inline std::atomic<bool> feedActive{false};
// The process's tracker. Never destroyed: the feed reader may still be running while
// static destructors run at exit.
inline Tracker& tracker() {
    static Tracker* instance = new Tracker;
    return *instance;
}

}  // namespace caboose::completion
