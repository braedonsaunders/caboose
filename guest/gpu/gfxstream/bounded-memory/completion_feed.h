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
#include <string>
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
                       uint64_t queue = 0, uint64_t device = 0, const std::vector<uint64_t>& commandBuffers = {}) {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t serial = ++lastSerial_;
        Watch watch;
        watch.queue = queue;
        watch.device = device;
        for (uint64_t cb : commandBuffers) {
            auto found = commandEvents_.find(cb);
            if (found == commandEvents_.end()) continue;
            for (const auto& op : found->second) {
                auto event = events_.find(op.first);
                if (event == events_.end() || event->second.state == EventState::Untracked) continue;
                ++event->second.pending;
                watch.events.push_back(op);
            }
        }
        for (uint64_t cb : commandBuffers) {
            auto found = commandQueries_.find(cb);
            if (found == commandQueries_.end()) continue;
            for (const auto& op : found->second) {
                auto& pool = queryPools_[op.pool];
                if (op.kind == QueryOp::Untrack) {
                    for (auto& entry : pool) entry.second.state = QueryState::Untracked;
                    continue;
                }
                const uint32_t count = std::min(op.count, kMaxQueryRange);
                for (uint32_t i = 0; i < count; ++i) {
                    QueryState& query = pool[op.first + i];
                    if (op.kind == QueryOp::End) {
                        query.state = QueryState::Pending;
                        query.serial = serial;
                        watch.queries.push_back({op.pool, op.first + i});
                    } else {
                        query = QueryState{};
                    }
                }
            }
        }
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
    // True once the watched submission `serial` has completed (or the feed ended).
    bool serialCompleted(uint64_t serial) {
        if (!serial) return true;
        std::lock_guard<std::mutex> lock(mutex_);
        return closed_ || (serial <= lastSerial_ && !watches_.count(serial));
    }
    // The oldest serial whose watch is outstanding, on any queue: every watch below it has
    // completed. One past the last serial when none is outstanding, and UINT64_MAX once the
    // feed has ended (nothing outstanding will be reported).
    uint64_t outstandingFrom() {
        std::lock_guard<std::mutex> lock(mutex_);
        return outstandingFromLocked();
    }
    // True once every watch up to and including `serial`, on every queue, has completed.
    bool completedThrough(uint64_t serial) { return serial < outstandingFrom(); }
    // Waits until completedThrough(serial) or `deadline`; whether it holds.
    bool waitCompletedThrough(uint64_t serial, Clock::time_point deadline) {
        std::unique_lock<std::mutex> lock(mutex_);
        return changed_.wait_until(lock, deadline, [&] { return serial < outstandingFromLocked(); });
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
    // --- Events ---------------------------------------------------------------------------
    // A D3D11 event query is a VkEvent that a command buffer sets and the application polls
    // (vkGetEventStatus). Every way an event changes is seen here: created reset, set or reset
    // on the host, or set or reset by a submitted command buffer once its batch completes, so
    // its state is known without asking the device.
    void eventCreated(uint64_t event) {
        std::lock_guard<std::mutex> lock(mutex_);
        events_[event] = EventInfo{};
    }
    void eventDestroyed(uint64_t event) {
        std::lock_guard<std::mutex> lock(mutex_);
        events_.erase(event);
    }
    void eventHost(uint64_t event, bool set) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = events_.find(event);
        if (it != events_.end() && it->second.state != EventState::Untracked)
            it->second.state = set ? EventState::Set : EventState::Reset;
        changed_.notify_all();
    }
    // Recording: a command buffer begun anew, an event set or reset in it, secondaries run in it.
    void commandBufferBegun(uint64_t commandBuffer) {
        std::lock_guard<std::mutex> lock(mutex_);
        commandEvents_.erase(commandBuffer);
        commandQueries_.erase(commandBuffer);
    }
    void commandBufferEvent(uint64_t commandBuffer, uint64_t event, bool set) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& ops = commandEvents_[commandBuffer];
        if (ops.size() < kMaxCommandEvents) ops.push_back({event, set});
        else untrackLocked(event);  // too many to follow: asked on the device
    }
    void commandBufferExecutes(uint64_t primary, const uint64_t* secondaries, uint32_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (uint32_t i = 0; i < count; ++i) {
            auto found = commandEvents_.find(secondaries[i]);
            if (found == commandEvents_.end()) continue;
            const auto ops = found->second;
            auto& into = commandEvents_[primary];
            for (const auto& op : ops) {
                if (into.size() < kMaxCommandEvents) into.push_back(op);
                else untrackLocked(op.first);
            }
        }
        for (uint32_t i = 0; i < count; ++i) {
            auto found = commandQueries_.find(secondaries[i]);
            if (found == commandQueries_.end()) continue;
            const auto ops = found->second;
            for (const auto& op : ops) addQueryOpLocked(primary, op);
        }
    }
    void commandBufferFreed(uint64_t commandBuffer) {
        std::lock_guard<std::mutex> lock(mutex_);
        commandEvents_.erase(commandBuffer);
        commandQueries_.erase(commandBuffer);
    }
    // Whether any of these command buffers sets or resets an event: its batch needs a watch.
    bool setsEvents(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (uint64_t cb : commandBuffers)
            if (commandEvents_.count(cb)) return true;
        return false;
    }
    // The events these command buffers set or reset.
    std::vector<uint64_t> eventsOf(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<uint64_t> out;
        for (uint64_t cb : commandBuffers) {
            auto found = commandEvents_.find(cb);
            if (found == commandEvents_.end()) continue;
            for (const auto& op : found->second)
                if (std::find(out.begin(), out.end(), op.first) == out.end()) out.push_back(op.first);
        }
        return out;
    }
    // A batch whose completion nobody will report: the events it touches are asked on the device.
    void eventsUntracked(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (uint64_t cb : commandBuffers) {
            auto found = commandEvents_.find(cb);
            if (found == commandEvents_.end()) continue;
            for (const auto& op : found->second) untrackLocked(op.first);
        }
    }
    // The event's state, or false when the device must be asked.
    bool eventSet(uint64_t event, bool* set) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (lost_) return false;
        auto it = events_.find(event);
        if (it == events_.end() || it->second.state == EventState::Untracked) return false;
        *set = it->second.state == EventState::Set;
        return true;
    }

    // --- Queries --------------------------------------------------------------------------
    // A query's result is available once the batch whose command buffer ended it (a query
    // end or a timestamp write) has completed, and unavailable from a reset (on the host, or
    // in a submitted batch) until then, so a poll without WAIT needs no request while the
    // result cannot be there yet.
    void commandBufferQueries(uint64_t commandBuffer, uint64_t pool, uint32_t first, uint32_t count, bool end) {
        std::lock_guard<std::mutex> lock(mutex_);
        addQueryOpLocked(commandBuffer, QueryOp{pool, first, count, end ? QueryOp::End : QueryOp::Reset});
    }
    // Whether these command buffers end or reset queries: their batch needs a watch.
    bool touchesQueries(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (uint64_t cb : commandBuffers)
            if (commandQueries_.count(cb)) return true;
        return false;
    }
    void queriesReset(uint64_t pool, uint32_t first, uint32_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto& queries = queryPools_[pool];
        const uint32_t n = std::min(count, kMaxQueryRange);
        for (uint32_t i = 0; i < n; ++i) queries[first + i] = QueryState{};
    }
    void queryPoolDestroyed(uint64_t pool) {
        std::lock_guard<std::mutex> lock(mutex_);
        queryPools_.erase(pool);
    }
    enum class Queries { Available, NotReady, AskDevice };
    // Whether every query of the range is available; AskDevice when any is not followed.
    Queries queries(uint64_t pool, uint32_t first, uint32_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (lost_ || !count || count > kMaxQueryRange) return Queries::AskDevice;
        auto found = queryPools_.find(pool);
        if (found == queryPools_.end()) return Queries::AskDevice;
        bool ready = true;
        for (uint32_t i = 0; i < count; ++i) {
            auto query = found->second.find(first + i);
            if (query == found->second.end() || query->second.state == QueryState::Untracked) return Queries::AskDevice;
            if (query->second.state != QueryState::Available) ready = false;
        }
        return ready ? Queries::Available : Queries::NotReady;
    }
    std::string describeQuery(uint64_t pool, uint32_t index) {
        std::lock_guard<std::mutex> lock(mutex_);
        static const char* const names[] = {"reset", "pending", "available", "untracked"};
        std::string out = "query=";
        const QueryState* query = nullptr;
        auto found = queryPools_.find(pool);
        if (found != queryPools_.end()) {
            auto entry = found->second.find(index);
            if (entry != found->second.end()) query = &entry->second;
        }
        if (!query) {
            out += "unknown";
        } else {
            out += names[int(query->state)];
            if (query->serial)
                out += " serial=" + std::to_string(query->serial) +
                       (watches_.count(query->serial) ? " (watch outstanding)" : " (watch answered)");
        }
        return out + describeLocked();
    }

    // What the tracker knows of a fence or timeline, for a stalled poll's log line.
    std::string describeFence(uint64_t fence) {
        std::lock_guard<std::mutex> lock(mutex_);
        static const char* const names[] = {"unsignaled", "signaled", "pending", "untracked"};
        auto it = fences_.find(fence);
        std::string out = "fence=";
        out += it == fences_.end() ? "unknown" : names[int(it->second.state)];
        if (it != fences_.end() && it->second.serial)
            out += " serial=" + std::to_string(it->second.serial) +
                   (watches_.count(it->second.serial) ? " (watch outstanding)" : " (watch answered)");
        return out + describeLocked();
    }
    std::string describeEvent(uint64_t event) {
        std::lock_guard<std::mutex> lock(mutex_);
        static const char* const names[] = {"reset", "set", "untracked"};
        auto it = events_.find(event);
        std::string out = "event=";
        if (it == events_.end()) out += "unknown";
        else out += std::string(names[int(it->second.state)]) + " pending_batches=" + std::to_string(it->second.pending);
        return out + describeLocked();
    }
    std::string describeSemaphore(uint64_t semaphore) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        std::string out = "timeline=";
        if (it == semaphores_.end()) out += "unknown";
        else out += std::string(it->second.tracked ? "tracked" : "untracked") + " value=" +
                    std::to_string(it->second.value) + " pending=" + std::to_string(it->second.pending);
        return out + describeLocked();
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
        for (const auto& [event, set] : watch.events) {
            auto found = events_.find(event);
            if (found == events_.end()) continue;
            if (found->second.pending) --found->second.pending;
            if (status != kCompleted) found->second.state = EventState::Untracked;
            else if (found->second.state != EventState::Untracked)
                found->second.state = set ? EventState::Set : EventState::Reset;
        }
        for (const auto& [poolHandle, index] : watch.queries) {
            auto pool = queryPools_.find(poolHandle);
            if (pool == queryPools_.end()) continue;
            auto query = pool->second.find(index);
            if (query == pool->second.end() || query->second.state != QueryState::Pending ||
                query->second.serial != serial) continue;
            query->second.state = status == kCompleted ? QueryState::Available : QueryState::Untracked;
            query->second.serial = 0;
        }
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
        for (auto& [handle, state] : events_) state.state = EventState::Untracked;
        queryPools_.clear();
        commandQueries_.clear();
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
    uint64_t outstandingFromLocked() const {
        if (closed_) return UINT64_MAX;
        uint64_t oldest = lastSerial_ + 1;
        for (const auto& entry : watches_) oldest = std::min(oldest, entry.first);
        return oldest;
    }
    std::string describeLocked() const {
        std::string out = " last_serial=" + std::to_string(lastSerial_) + " watches=" + std::to_string(watches_.size());
        if (!watches_.empty()) {
            uint64_t oldest = UINT64_MAX;
            for (const auto& entry : watches_) oldest = std::min(oldest, entry.first);
            out += " oldest_watch=" + std::to_string(oldest);
        }
        if (closed_) out += " feed=closed";
        if (lost_) out += " lost";
        return out;
    }
    struct FenceState { Fence state = Fence::Unsignaled; uint64_t serial = 0; uint64_t device = 0; };
    struct SemaphoreState { bool tracked = false; uint64_t value = 0; uint64_t pending = 0; uint64_t device = 0; };
    struct Watch {
        uint64_t fence = 0, queue = 0, device = 0;
        std::vector<std::pair<uint64_t, uint64_t>> signals;
        std::vector<std::pair<uint64_t, bool>> events;  // set (true) or reset, in order
        std::vector<std::pair<uint64_t, uint32_t>> queries;  // (pool, index) ended in the batch
    };
    // A query as the process knows it. Reset: reset and not ended since (never available).
    struct QueryState {
        enum State { Reset, Pending, Available, Untracked } state = Reset;
        uint64_t serial = 0;  // the watch of the batch that ends it, while Pending
    };
    struct QueryOp {
        uint64_t pool;
        uint32_t first, count;
        enum Kind { End, Reset, Untrack } kind;
    };
    static constexpr uint32_t kMaxQueryRange = 65536;
    static constexpr size_t kMaxCommandQueries = 4096;
    void addQueryOpLocked(uint64_t commandBuffer, const QueryOp& op) {
        auto& ops = commandQueries_[commandBuffer];
        if (ops.size() < kMaxCommandQueries) {
            ops.push_back(op);
        } else {
            // Too many to follow: the batch leaves the pool's queries to the device.
            ops.back() = QueryOp{op.pool, 0, 0, QueryOp::Untrack};
        }
    }
    std::unordered_map<uint64_t, std::unordered_map<uint32_t, QueryState>> queryPools_;
    std::unordered_map<uint64_t, std::vector<QueryOp>> commandQueries_;
    // An event's state as the process knows it: from the host's own sets and resets, and
    // from the completed batches whose command buffers set or reset it.
    enum class EventState { Reset, Set, Untracked };
    struct EventInfo { EventState state = EventState::Reset; uint32_t pending = 0; };

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
    static constexpr size_t kMaxCommandEvents = 256;
    void untrackLocked(uint64_t event) {
        auto it = events_.find(event);
        if (it != events_.end()) it->second.state = EventState::Untracked;
    }
    std::unordered_map<uint64_t, EventInfo> events_;
    std::unordered_map<uint64_t, std::vector<std::pair<uint64_t, bool>>> commandEvents_;
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
// streams ended). Cleared when a later instance reconnects the process's stream to a
// new executor (executorConnected).
inline std::atomic<bool> executorLost{false};
// Counts executor losses: work asked for under one executor connection is never sent on a
// later one.
// Serialize reconnect with emission of generation-fenced retirement packets.
inline std::mutex transportEpochMutex;
inline std::atomic<uint64_t> executorGeneration{0};
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
inline std::atomic<uint64_t> lostSocketInode{0};
inline std::mutex& lostCallsMutex() {
    static std::mutex* instance = new std::mutex;
    return *instance;
}
inline std::unordered_set<std::string>& lostCallsTold() {
    static auto* instance = new std::unordered_set<std::string>;
    return *instance;
}
// The executor generation this process is connected to: 1 for its first executor, one more
// for each executor it connected to after losing the one before (docs/gpu-live.md, Executor
// generations). Every dispatchable object records the generation it was made under; a call on
// an object of an earlier generation reports VK_ERROR_DEVICE_LOST and never reaches the
// executor, which does not know its handles.
inline std::atomic<uint64_t> connectionGeneration{1};
// What a new executor generation resets: every cache of an executor's answers and every
// table of its objects that is not itself keyed by generation registers here, so one place
// re-establishes the process for the new executor (docs/gpu-live.md, Executor generations).
// Hooks run on the reconnecting thread, after the generation has advanced and before the
// first call of the new generation.
using GenerationHook = void (*)();
inline std::mutex& generationHooksMutex() {
    static std::mutex* instance = new std::mutex;
    return *instance;
}
inline std::vector<GenerationHook>& generationHooks() {
    static auto* instance = new std::vector<GenerationHook>;
    return *instance;
}
inline bool onNewGeneration(GenerationHook hook) {
    std::lock_guard<std::mutex> lock(generationHooksMutex());
    generationHooks().push_back(hook);
    return true;
}
// CABOOSE_GPU_ON_LOSS=pause: the process must not restart while the phone is away. Its
// devices cannot survive the executor (their objects lived there), so every call that would
// report the loss first waits until a new executor is available, then reports it; the
// application recreates its device on the returned phone. Any other value, the launch
// environment's `auto` included, reports loss at once (restart): every process is treated
// alike, and one that recovers from device loss keeps running on the computer meanwhile.
inline bool lossPolicyPauses(const char* mode) { return mode && std::strcmp(mode, "pause") == 0; }
// CABOOSE_GPU_ON_LOSS=quiet: a process that learns of an executor's loss another way (the
// compositor, from its broker) gets a lost device that keeps answering as a working one: its
// submissions are dropped and complete at once, its waits are satisfied, and nothing reports
// VK_ERROR_DEVICE_LOST, so its GL implementation never takes its device-loss paths (Zink's
// teardown of a lost device does not end). It makes its renderer again when told.
inline bool quietOnLoss() {
    static const bool quiet = [] {
        const char* mode = std::getenv("CABOOSE_GPU_ON_LOSS");
        return mode && std::strcmp(mode, "quiet") == 0;
    }();
    return quiet;
}
// The result a call on a lost device gives where it would report the loss.
inline int32_t lostResult() { return quietOnLoss() ? 0 : -4; }
inline bool pauseOnLoss() {
    static const bool pause = lossPolicyPauses(std::getenv("CABOOSE_GPU_ON_LOSS"));
    return pause;
}
// The socket the lost executor was reached through, if it is still there (a broker that
// did not remove it): a returned executor is a socket made since.
// Inode numbers are reused, so a socket is identified by its inode and change time.
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
// How long a loss that may be the executor's departure is held before it is taken for
// something else: the host relay ends a silent phone's executor within 3 s, and the broker
// removes the executor's socket as it ends its streams.
inline std::atomic<int> departureGraceMs{10000};
// Waits until `done()` holds, at most the departure grace; whether it held.
template <typename Done> inline bool withinDepartureGrace(Done done) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(departureGraceMs.load());
    for (;;) {
        if (done()) return true;
        if (std::chrono::steady_clock::now() >= end) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }
}
// The broker makes its socket when it has a ready executor and removes it when the
// executor leaves.
inline void awaitExecutorReturn() {
    if (!pauseOnLoss() || !executorLost.load(std::memory_order_acquire)) return;
    if (!std::getenv("CABOOSE_GFXSTREAM_SOCKET")) return;
    // A device stream can end before the broker has removed the executor's socket. A
    // socket that is still the same once the grace has passed means one stream failed
    // while the executor stayed: nothing returns, and the loss is reported at once.
    if (lostSocketInode.load() &&
        !withinDepartureGrace([] { return socketInode() != lostSocketInode.load(); })) return;
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
// Encoder calls after the executor is gone: true when the call must not reach the
// stream (it reports device loss without touching its outputs), after a paused
// application's wait for a new executor.
// A call that returns without the device once its executor is gone: its outputs are left
// as the caller had them (a query reads as all zeros). Each kind of call says so once per
// connection generation, so an answer of zeros can be told from the device's.
inline bool lostCall(const char* caller = __builtin_FUNCTION()) {
    if (!executorLost.load(std::memory_order_acquire)) return false;
    awaitExecutorReturn();
    {
        std::lock_guard<std::mutex> lock(lostCallsMutex());
        auto& told = lostCallsTold();
        if (told.size() < 512 && told.insert(caller).second)
            std::fprintf(stderr, "CABOOSE_GPU_LOST_CALL %s returned without the device (executor lost)\n", caller);
    }
    return true;
}
// A call on an object made under executor `generation` (0: an object no generation was
// recorded for): true when it must not reach the stream, either because the executor is gone
// or because the object belongs to an executor this process has since replaced.
inline bool lostCall(uint64_t generation, const char* caller = __builtin_FUNCTION()) {
    if (generation && generation != connectionGeneration.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lock(lostCallsMutex());
        auto& told = lostCallsTold();
        if (told.size() < 512 && told.insert(std::string("stale:") + caller).second)
            std::fprintf(stderr, "CABOOSE_GPU_LOST_CALL %s on an object of executor generation %llu, now %llu\n", caller,
                         (unsigned long long)generation, (unsigned long long)connectionGeneration.load());
        return true;
    }
    return lostCall(caller);
}
inline void markExecutorLost() {
    if (executorLost.exchange(true, std::memory_order_acq_rel)) return;
    executorGeneration.fetch_add(1, std::memory_order_acq_rel);
    lostSocketInode.store(socketInode());
    std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_LOST\n");
    tracker().loseAll();
}
// A device stream connected to a (new) executor. A connection to another executor than the
// one the process last connected to is a new generation even when none of the process's
// streams had ended yet: an idle process learns of the change only by connecting.
inline void executorConnected() {
    static std::mutex* serial = new std::mutex;
    std::lock_guard<std::mutex> lock(*serial);
    const uint64_t socket = socketInode(), previous = connectedSocketId.load();
    if (previous && socket && socket != previous) markExecutorLost();
    lostSocketInode.store(0, std::memory_order_release);
    if (!executorLost.load(std::memory_order_acquire)) return;
    // The generation advances before the loss is cleared: a thread checking an object of the
    // lost generation meanwhile sees the loss or the newer generation, never neither.
    connectionGeneration.fetch_add(1, std::memory_order_acq_rel);
    std::vector<GenerationHook> hooks;
    {
        std::lock_guard<std::mutex> hooksLock(generationHooksMutex());
        hooks = generationHooks();
    }
    for (GenerationHook hook : hooks) hook();
    {
        std::lock_guard<std::mutex> toldLock(lostCallsMutex());
        lostCallsTold().clear();
    }
    tracker().revive();
    executorLost.store(false, std::memory_order_release);
}
// A result the executor returned. VK_ERROR_DEVICE_LOST from a phone whose app is closing
// arrives before its streams end; for a paused application it is held like the executor's
// own departure when the executor leaves within the grace, and reported once a new one is
// there. A loss while the executor stays is the device's own and is reported after the grace.
template <typename Result> inline Result heldLoss(Result result) {
    if (int32_t(result) != -4 || !pauseOnLoss() || !std::getenv("CABOOSE_GFXSTREAM_SOCKET")) return result;
    if (withinDepartureGrace([] { return executorLost.load(std::memory_order_acquire); })) awaitExecutorReturn();
    return result;
}

}  // namespace caboose::completion
