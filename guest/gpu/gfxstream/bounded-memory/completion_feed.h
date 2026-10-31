// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sys/stat.h>
#include <thread>
#include <cstring>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
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
// With hello feature 0x400: everything sent on this device stream before the mark must be
// decoded before the ordered present naming the mark's serial runs.
inline constexpr uint32_t kOrderOpcode = 0x4342FE03;  // payload: serial u64
inline constexpr uint32_t kFeedVersion = 1;
inline constexpr uint32_t kFeedPacketSize = 16;
inline constexpr uint32_t kWatchPacketSize = 24;
inline constexpr uint32_t kOrderPacketSize = 16;
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
inline void encodeOrder(uint8_t out[kOrderPacketSize], uint64_t serial) {
    const uint32_t opcode = kOrderOpcode, size = kOrderPacketSize;
    std::memcpy(out, &opcode, 4);
    std::memcpy(out + 4, &size, 4);
    std::memcpy(out + 8, &serial, 8);
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
        changed_.notify_all();  // a waiter now asks the device
    }
    Fence fence(uint64_t fence) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = fences_.find(fence);
        return it == fences_.end() ? Fence::Untracked : it->second.state;
    }
    // A submission's signal operations on `queue`, before it is sent. Returns the serial
    // to watch.
    uint64_t submitted(uint64_t fence, const std::vector<std::pair<uint64_t, uint64_t>>& timelineSignals,
                       uint64_t queue = 0, uint64_t device = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t serial = ++lastSerial_;
        Watch watch;
        watch.queue = queue;
        watch.device = device;
        if (fence) {
            auto& state = fences_[fence];
            state.state = Fence::Pending;
            state.serial = serial;
            state.device = device;
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
    // The latest serial handed out; an idle wait sent after it covers it.
    uint64_t lastSerial() {
        std::lock_guard<std::mutex> lock(mutex_);
        return lastSerial_;
    }
    // The device reported `queue` idle (vkQueueWaitIdle), or every queue of `device`
    // (vkDeviceWaitIdle, queue 0), for a wait sent after serial `through`: every watched
    // submission there up to it has completed, even if its record is still in flight.
    void idle(uint64_t queue, uint64_t device, uint64_t through) {
        std::vector<uint64_t> serials;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            for (const auto& [serial, watch] : watches_)
                if (serial <= through && (queue ? watch.queue == queue : watch.device == device))
                    serials.push_back(serial);
        }
        for (uint64_t serial : serials) complete(serial, kCompleted);
    }

    // --- Timeline semaphores ------------------------------------------------------------
    void timelineCreated(uint64_t semaphore, uint64_t initialValue, uint64_t device = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        semaphores_[semaphore] = SemaphoreState{true, initialValue, initialValue, device};
    }
    void semaphoreDestroyed(uint64_t semaphore) {
        std::lock_guard<std::mutex> lock(mutex_);
        semaphores_.erase(semaphore);
    }
    void semaphoreUntracked(uint64_t semaphore) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        if (it != semaphores_.end()) it->second.tracked = false;
        changed_.notify_all();  // a waiter now asks the device
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
            if (watch.device) lostDevices_.insert(watch.device);
            else lost_ = true;
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
    // The executor is gone: every device of this process is lost.
    void loseAll() {
        std::lock_guard<std::mutex> lock(mutex_);
        lost_ = true;
        closed_ = true;
        changed_.notify_all();
    }
    // A new executor connection after a loss: objects of the lost devices are asked about
    // on their own (ended) streams, which report device loss; new objects are tracked.
    void revive() {
        std::lock_guard<std::mutex> lock(mutex_);
        for (auto& [handle, state] : fences_)
            if (state.state == Fence::Pending) { state.state = Fence::Untracked; state.serial = 0; }
        for (auto& [handle, state] : semaphores_) state.tracked = false;
        watches_.clear();
        lost_ = false;
        lostDevices_.clear();
        closed_ = false;
        changed_.notify_all();
    }
    // The feed ended: nothing pending will be reported any more.
    void feedClosed() {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = true;
        changed_.notify_all();
    }
    bool deviceLost(uint64_t device = 0) {
        std::lock_guard<std::mutex> lock(mutex_);
        return lost_ || (device && lostDevices_.count(device));
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
    struct FenceState { Fence state = Fence::Unsignaled; uint64_t serial = 0; uint64_t device = 0; };
    struct SemaphoreState { bool tracked = false; uint64_t value = 0; uint64_t pending = 0; uint64_t device = 0; };
    struct Watch {
        uint64_t fence = 0, queue = 0, device = 0;
        std::vector<std::pair<uint64_t, uint64_t>> signals;
    };

    Answer fencesLocked(const uint64_t* fences, uint32_t count, bool all) {
        if (lost_) return Answer::DeviceLost;
        uint32_t signaled = 0;
        for (uint32_t i = 0; i < count; ++i) {
            auto it = fences_.find(fences[i]);
            if (it == fences_.end() || it->second.state == Fence::Untracked) return Answer::AskDevice;
            if (it->second.device && lostDevices_.count(it->second.device)) return Answer::DeviceLost;
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
            if (it->second.device && lostDevices_.count(it->second.device)) return Answer::DeviceLost;
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
    bool lost_ = false;                         // a loss not tied to a known device
    std::unordered_set<uint64_t> lostDevices_;
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
// Set once the phone executor this process's Vulkan objects live on is gone (its
// streams ended). Never cleared: every device is lost and the application recreates
// its instance, which then finds whichever executor exists.
inline std::atomic<bool> executorLost{false};
}  // namespace caboose::completion
extern "C" void caboose_read_profile_wait(uint64_t us, uint32_t what);
namespace caboose::completion {
// Reports the time a local wait took to CABOOSE_READ_PROFILE (`what`: the Vulkan opcode,
// or 21001-21004 for the presentation client's waits for the phone).
struct WaitTimer {
    uint32_t what;
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    ~WaitTimer() {
        caboose_read_profile_wait(uint64_t(std::chrono::duration_cast<std::chrono::microseconds>(
                                      std::chrono::steady_clock::now() - start).count()), what);
    }
};
// A device stream connected to a (new) executor.
inline void executorConnected() {
    if (executorLost.exchange(false, std::memory_order_acq_rel)) tracker().revive();
}
// CABOOSE_GPU_ON_LOSS=pause: an application that must not restart while the phone is away.
// Its devices cannot survive the executor (their objects lived there), so every call that
// would report the loss first waits until a new executor is available, then reports it;
// the application recreates its device on the returned phone. Otherwise loss is reported
// at once (restart, the default).
inline bool pauseOnLoss() {
    static const bool pause = [] {
        const char* mode = std::getenv("CABOOSE_GPU_ON_LOSS");
        return mode && std::strcmp(mode, "pause") == 0;
    }();
    return pause;
}
// The socket the lost executor was reached through, if it is still there (a broker that
// did not remove it): a returned executor is a socket made since.
// Inode numbers are reused, so a socket is identified by its inode and change time.
inline std::atomic<uint64_t> lostSocketInode{0};
inline uint64_t socketInode() {
    const char* path = std::getenv("CABOOSE_GFXSTREAM_SOCKET");
    struct stat info;
    if (!path || !*path || stat(path, &info) != 0 || !S_ISSOCK(info.st_mode)) return 0;
#if defined(__APPLE__)
    const uint64_t changed = uint64_t(info.st_ctimespec.tv_sec) * 1000000000ull + uint64_t(info.st_ctimespec.tv_nsec);
#else
    const uint64_t changed = uint64_t(info.st_ctim.tv_sec) * 1000000000ull + uint64_t(info.st_ctim.tv_nsec);
#endif
    return (uint64_t(info.st_ino) * 1000003ull) ^ changed ^ 1;  // never 0
}
// The broker makes its socket when it has a ready executor and removes it when the
// executor leaves.
inline void awaitExecutorReturn() {
    if (!pauseOnLoss() || !executorLost.load(std::memory_order_acquire)) return;
    if (!std::getenv("CABOOSE_GFXSTREAM_SOCKET")) return;
    // The broker removes its socket before it ends an executor's streams: a socket still
    // there at the loss means one stream failed while the executor stayed. Nothing returns.
    if (lostSocketInode.load()) return;
    static std::atomic<bool> noted{false};
    if (!noted.exchange(true)) std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_PAUSED until a phone executor returns\n");
    for (;;) {
        const uint64_t inode = socketInode();
        if (inode && inode != lostSocketInode.load()) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
}
// The socket of the executor this process connected to.
inline std::atomic<uint64_t> connectedSocketId{0};
inline void noteExecutorSocket() { connectedSocketId.store(socketInode()); }
inline void markExecutorLost();
// A stream other than the device stream ended (the feed, a surface connection): the
// executor is lost only if its socket is gone or replaced; otherwise only that stream is.
inline void executorEndedIfGone() {
    const uint64_t now = socketInode();
    if (!now || now != connectedSocketId.load()) markExecutorLost();
}
inline void markExecutorLost() {
    if (executorLost.exchange(true, std::memory_order_acq_rel)) return;
    lostSocketInode.store(socketInode());
    std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_LOST\n");
    tracker().loseAll();
}

}  // namespace caboose::completion
