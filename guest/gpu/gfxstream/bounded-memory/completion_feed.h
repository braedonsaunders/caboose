// SPDX-License-Identifier: MIT
#pragma once
#include "completion_payloads.h"
#include "gpu_writes.h"
#include "lock_order.h"
#include "write_watch.h"
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
#include <pthread.h>
#include <map>
#include <memory>
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

// The waits in progress (WaitTimer, below): who waits, for what and since when, so a stalled
// poll or wait can say which other threads have been waiting long (a thread that never
// returns from a wait reports nothing itself). Its own mutex, a leaf: taken under any lock.
class WaitsInProgress {
public:
    uint64_t begin(uint32_t what) {
        char name[16] = "?";
        pthread_getname_np(pthread_self(), name, sizeof name);
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t id = ++next_;
        if (waits_.size() < 256) waits_[id] = {name, what, std::chrono::steady_clock::now()};
        return id;
    }
    void end(uint64_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        waits_.erase(id);
    }
    // " waiting=thread:what:seconds,..." for the waits at least `atLeast` old; empty if none.
    std::string older(std::chrono::steady_clock::duration atLeast) {
        std::lock_guard<std::mutex> lock(mutex_);
        const auto now = std::chrono::steady_clock::now();
        std::string out;
        for (const auto& [id, wait] : waits_) {
            if (now - wait.since < atLeast) continue;
            out += out.empty() ? " waiting=" : ",";
            out += wait.thread + ":" + std::to_string(wait.what) + ":" +
                   std::to_string(std::chrono::duration_cast<std::chrono::seconds>(now - wait.since).count()) + "s";
        }
        return out;
    }

private:
    struct Wait { std::string thread; uint32_t what; std::chrono::steady_clock::time_point since; };
    std::mutex mutex_;
    uint64_t next_ = 0;
    std::map<uint64_t, Wait> waits_;
};
inline WaitsInProgress& waitsInProgress() {
    static WaitsInProgress* instance = new WaitsInProgress;  // never destroyed, as the tracker
    return *instance;
}

// Wire, little-endian. Both commands use the ordinary 8-byte gfxstream packet header
// (opcode, total packet size); neither has a reply on its own stream.
inline constexpr uint32_t kFeedOpcode = 0x4342FE01;   // payload: version u32 = 1, reserved u32 = 0
inline constexpr uint32_t kWatchOpcode = 0x4342FE02;  // payload: boxed queue u64, serial u64
// With hello feature 0x400: everything sent on this device stream before the mark must be
// decoded before the ordered present naming the mark's serial runs.
inline constexpr uint32_t kOrderOpcode = 0x4342FE03;  // payload: serial u64
// With hello feature 0x400000: the decoder decodes nothing more from this device stream until
// the watch `serial` has its record (Speculation, below).
inline constexpr uint32_t kWaitSerialOpcode = 0x4342FE04;  // payload: watch serial u64
inline constexpr uint32_t kFeedVersion = 1;
inline constexpr uint32_t kFeedPacketSize = 16;
inline constexpr uint32_t kWatchPacketSize = 24;
inline constexpr uint32_t kOrderPacketSize = 16;
inline constexpr uint32_t kWaitSerialPacketSize = 16;
// A feed record's header: serial u64, status i32, payload bytes u32 (0 for a watch's record),
// then the payload (silent_success.h readRecord).
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
inline void encodeWaitSerial(uint8_t out[kWaitSerialPacketSize], uint64_t serial) {
    const uint32_t opcode = kWaitSerialOpcode, size = kWaitSerialPacketSize;
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
// seen, and of its events and queries; with completion payloads (completion_payloads.h), of
// its queries' values too, and the coherent memory its batches write is captured for it. An
// object stays "tracked" only while each of its signal operations is either a
// watched submission or done by the guest itself; any other (an imported payload, a
// presentation-engine acquire, a submission the phone cannot watch) makes it untracked
// until a reset, and the caller then asks the device as before.
class Tracker {
public:
    enum class Fence { Unsignaled, Signaled, Pending, Untracked };
    using Clock = std::chrono::steady_clock;

    // --- Completion payloads (hello 0x200000) ---------------------------------------------
    // A range of coherent memory a batch writes on the GPU: the guest's key of the
    // allocation, the phone's handle of it, and the bytes [offset, offset + size).
    struct MemoryWrite { uint64_t memory, handle, offset, size; };
    // What a watch asks the phone to capture: in, the batch's memory writes; out, the
    // COMPLETION_WATCH2 entries (empty: a plain watch).
    struct Captures {
        std::vector<MemoryWrite> memory;
        std::vector<payloads::Entry> entries;
    };
    // What a submission waits for and signals, for speculation (Speculation, below): its
    // batches' semaphore waits (with the timeline value, 0 for a binary semaphore), every
    // semaphore they signal, whether they write host-visible memory the guest refreshes, and
    // the device stream (an encoder's key) its watch goes out on; 0 when that is not the
    // process's only device stream.
    struct Batch {
        std::vector<std::pair<uint64_t, uint64_t>> waits;
        std::vector<uint64_t> signaled;
        bool hostWrites = false;
        uint64_t stream = 0;
    };
    // Where captured bytes of an allocation go: its guest shadow, kept alive while written,
    // the offsets [begin, end) of it that may be written, and the allocation's size.
    struct MemoryTarget {
        std::shared_ptr<uint8_t> keep;
        uint8_t* base = nullptr;
        uint64_t begin = 0, end = 0, allocation = 0;
    };
    // Set by the driver: finds an allocation's shadow (false when it has none), and is told
    // of bytes stored there. Neither is called with this tracker's lock held.
    using ResolveMemory = bool (*)(uint64_t memory, MemoryTarget* out);
    using StoredMemory = void (*)(uint64_t memory, const MemoryTarget& target, uint64_t offset, uint64_t size);
    void memoryHooks(ResolveMemory resolve, StoredMemory stored) {
        resolve_.store(resolve, std::memory_order_release);
        stored_.store(stored, std::memory_order_release);
    }

    // --- Fences -----------------------------------------------------------------------
    void fenceCreated(uint64_t fence, bool signaled) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto& state = fences_[fence];
        state = FenceState{};
        state.state = signaled ? Fence::Signaled : Fence::Unsignaled;
    }
    void fenceDestroyed(uint64_t fence) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        fences_.erase(fence);
        externalFences_.erase(fence);
    }
    void fenceReset(uint64_t fence) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto& state = fences_[fence];
        state.state = Fence::Unsignaled;
        state.serial = 0;
    }
    // A signal operation the guest cannot follow.
    void fenceUntracked(uint64_t fence) {
        if (!fence) return;
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto& state = fences_[fence];
        state.state = Fence::Untracked;
        state.serial = 0;
        changed_.notify_all();  // a waiter now asks the device
    }
    Fence fence(uint64_t fence) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto it = fences_.find(fence);
        return it == fences_.end() ? Fence::Untracked : it->second.state;
    }
    // A submission's signal operations on `queue`, before it is sent. Returns the serial
    // to watch.
    // With `captures`, the watch is COMPLETION_WATCH2: its entries name the batch's ended
    // queries of captured pools and its memory writes, within one record's payload.
    // With `batch`, a wait for the watch may be speculated (Speculation, below); without, never.
    uint64_t submitted(uint64_t fence, const std::vector<std::pair<uint64_t, uint64_t>>& timelineSignals,
                       uint64_t queue = 0, uint64_t device = 0, const std::vector<uint64_t>& commandBuffers = {},
                       Captures* captures = nullptr, const Batch* batch = nullptr) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        const uint64_t serial = ++lastSerial_;
        Watch watch;
        watch.queue = queue;
        watch.device = device;
        // Whether its command buffers set, reset or wait for an event, or end or reset a query,
        // followed or not.
        bool touched = false;
        for (uint64_t cb : commandBuffers) {
            if (commandWaits_.count(cb)) watch.waitsEvents = true;
            auto found = commandEvents_.find(cb);
            if (found == commandEvents_.end()) continue;
            touched = true;
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
            touched = true;
            for (const auto& op : found->second) {
                auto& pool = queryPools_[op.pool];
                if (op.kind == QueryOp::Untrack) {
                    for (auto& entry : pool) entry.second.state = QueryState::Untracked;
                    continue;
                }
                const uint32_t count = std::min(op.count, kMaxQueryRange);
                for (uint32_t i = 0; i < count; ++i) {
                    QueryState& query = pool[op.first + i];
                    query.known = false;
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
        bool fenceFollowed = true;
        if (fence) {
            auto& state = fences_[fence];
            fenceFollowed = state.state != Fence::Untracked && !externalFences_.count(fence);
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
        if (captures) {
            requestLocked(serial, watch, *captures);
            captures->entries = watch.entries;
        }
        if (batch) classifyLocked(watch, *batch, fenceFollowed && !touched);
        watches_.emplace(serial, std::move(watch));
        return serial;
    }
    // A submission whose watch could not be sent: its objects are untracked.
    void unwatched(uint64_t serial) { complete(serial, kUnwatched); }
    // The latest serial handed out; an idle wait sent after it covers it.
    uint64_t lastSerial() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return lastSerial_;
    }
    // True once the watched submission `serial` has completed (or the feed ended).
    bool serialCompleted(uint64_t serial) {
        if (!serial) return true;
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return closed_ || (serial <= lastSerial_ && !watches_.count(serial));
    }
    // Whether watch `serial` is outstanding and was reported complete before its record came
    // (Speculation, below).
    bool speculated(uint64_t serial) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto it = watches_.find(serial);
        return it != watches_.end() && it->second.speculated;
    }
    // Blocks until watch `serial` has completed, its executor is lost or the feed ends (lazy
    // readback's fills, write_watch.h: their bytes are read once the batch that wrote them is
    // done).
    void waitCompleted(uint64_t serial) {
        std::unique_lock<decltype(mutex_)> lock(mutex_);
        changed_.wait(lock, [&] { return closed_ || !serial || (serial <= lastSerial_ && !watches_.count(serial)); });
    }
    // The oldest serial whose watch is outstanding, on any queue: every watch below it has
    // completed. One past the last serial when none is outstanding, and UINT64_MAX once the
    // feed has ended (nothing outstanding will be reported).
    uint64_t outstandingFrom() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return outstandingFromLocked();
    }
    // True once every watch up to and including `serial`, on every queue, has completed.
    bool completedThrough(uint64_t serial) { return serial < outstandingFrom(); }
    // Waits until completedThrough(serial) or `deadline`; whether it holds.
    bool waitCompletedThrough(uint64_t serial, Clock::time_point deadline) {
        std::unique_lock<decltype(mutex_)> lock(mutex_);
        return changed_.wait_until(lock, deadline, [&] { return serial < outstandingFromLocked(); });
    }
    // The device reported `queue` idle (vkQueueWaitIdle), or every queue of `device`
    // (vkDeviceWaitIdle, queue 0), for a wait sent after serial `through`: every watched
    // submission there up to it has completed, even if its record is still in flight.
    void idle(uint64_t queue, uint64_t device, uint64_t through) {
        std::vector<uint64_t> serials;
        {
            std::lock_guard<decltype(mutex_)> lock(mutex_);
            for (const auto& [serial, watch] : watches_)
                if (serial <= through && (queue ? watch.queue == queue : watch.device == device))
                    serials.push_back(serial);
        }
        // Their records, with what they captured, are still to come. A record whose captures
        // are being stored completes its watch itself once the shadows know of them: waited for,
        // so nothing after the idle wait sees those shadows before.
        for (uint64_t serial : serials) {
            std::unique_lock<decltype(mutex_)> lock(mutex_);
            changed_.wait(lock, [&] { return !storing_.count(serial); });
            auto it = watches_.find(serial);
            if (it == watches_.end()) continue;
            Watch watch = std::move(it->second);
            watches_.erase(it);
            finishWatchLocked(serial, kCompleted, std::move(watch), {}, true);
        }
    }

    // --- Timeline semaphores ------------------------------------------------------------
    void timelineCreated(uint64_t semaphore, uint64_t initialValue, uint64_t device = 0) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        semaphores_[semaphore] = SemaphoreState{true, initialValue, initialValue, device};
    }
    void semaphoreDestroyed(uint64_t semaphore) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        semaphores_.erase(semaphore);
        external_.erase(semaphore);
    }
    void semaphoreUntracked(uint64_t semaphore) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        if (it != semaphores_.end()) it->second.tracked = false;
        changed_.notify_all();  // a waiter now asks the device
    }
    // vkSignalSemaphore: the host sets the value directly.
    void timelineSignaledByHost(uint64_t semaphore, uint64_t value) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
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
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        events_[event] = EventInfo{};
    }
    void eventDestroyed(uint64_t event) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        events_.erase(event);
    }
    void eventHost(uint64_t event, bool set) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto it = events_.find(event);
        if (it != events_.end() && it->second.state != EventState::Untracked)
            it->second.state = set ? EventState::Set : EventState::Reset;
        changed_.notify_all();
    }
    // Recording: a command buffer begun anew, an event set or reset in it, secondaries run in it.
    void commandBufferBegun(uint64_t commandBuffer) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        commandEvents_.erase(commandBuffer);
        commandQueries_.erase(commandBuffer);
        commandWaits_.erase(commandBuffer);
    }
    void commandBufferEvent(uint64_t commandBuffer, uint64_t event, bool set) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto& ops = commandEvents_[commandBuffer];
        if (ops.size() < kMaxCommandEvents) ops.push_back({event, set});
        else untrackLocked(event);  // too many to follow: asked on the device
    }
    void commandBufferExecutes(uint64_t primary, const uint64_t* secondaries, uint32_t count) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        for (uint32_t i = 0; i < count; ++i)
            if (commandWaits_.count(secondaries[i])) commandWaits_.insert(primary);
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
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        commandEvents_.erase(commandBuffer);
        commandQueries_.erase(commandBuffer);
        commandWaits_.erase(commandBuffer);
    }
    // Whether any of these command buffers sets or resets an event: its batch needs a watch.
    bool setsEvents(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        for (uint64_t cb : commandBuffers)
            if (commandEvents_.count(cb)) return true;
        return false;
    }
    // The events these command buffers set or reset.
    std::vector<uint64_t> eventsOf(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
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
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        for (uint64_t cb : commandBuffers) {
            auto found = commandEvents_.find(cb);
            if (found == commandEvents_.end()) continue;
            for (const auto& op : found->second) untrackLocked(op.first);
        }
    }
    // The event's state, or false when the device must be asked.
    bool eventSet(uint64_t event, bool* set) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
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
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        addQueryOpLocked(commandBuffer, QueryOp{pool, first, count, end ? QueryOp::End : QueryOp::Reset});
    }
    // Whether these command buffers end or reset queries: their batch needs a watch.
    bool touchesQueries(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        for (uint64_t cb : commandBuffers)
            if (commandQueries_.count(cb)) return true;
        return false;
    }
    void queriesReset(uint64_t pool, uint32_t first, uint32_t count) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto& queries = queryPools_[pool];
        const uint32_t n = std::min(count, kMaxQueryRange);
        for (uint32_t i = 0; i < n; ++i) queries[first + i] = QueryState{};
    }
    void queryPoolDestroyed(uint64_t pool) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        queryPools_.erase(pool);
        capturedPools_.erase(pool);
    }
    // A query pool was made on `device` (`handle` is the phone's name of it): an occlusion or
    // timestamp pool has its queries' values captured with completion payloads, by watches of
    // that device's queues, and answered here.
    void queryPoolCreated(uint64_t pool, uint64_t handle, uint64_t device, int32_t queryType) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        queryPools_.erase(pool);
        if (payloads::capturedType(queryType)) capturedPools_[pool] = CapturedPool{handle, device};
        else capturedPools_.erase(pool);
    }
    // The decoder destroys a pool without a lock against the capture of its queries: a pool
    // is destroyed only once every record that captures it has arrived. Waits for those
    // records (or the feed's end); whether it had to.
    bool waitPoolCaptures(uint64_t pool) {
        std::unique_lock<decltype(mutex_)> lock(mutex_);
        auto outstanding = [&] {
            auto found = poolCaptures_.find(pool);
            return !closed_ && found != poolCaptures_.end() && found->second;
        };
        if (!outstanding()) return false;
        changed_.wait(lock, [&] { return !outstanding(); });
        return true;
    }
    bool poolCaptured(uint64_t pool) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto found = poolCaptures_.find(pool);
        return !closed_ && found != poolCaptures_.end() && found->second;
    }
    // A batch whose completion nobody will report: the queries it ends or resets are asked
    // on the device until they are reset again.
    void queriesUntracked(const std::vector<uint64_t>& commandBuffers) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        for (uint64_t cb : commandBuffers) {
            auto found = commandQueries_.find(cb);
            if (found == commandQueries_.end()) continue;
            for (const auto& op : found->second) {
                auto& pool = queryPools_[op.pool];
                if (op.kind == QueryOp::Untrack) {
                    for (auto& entry : pool) entry.second = untrackedQuery();
                    continue;
                }
                const uint32_t count = std::min(op.count, kMaxQueryRange);
                for (uint32_t i = 0; i < count; ++i) pool[op.first + i] = untrackedQuery();
            }
        }
    }
    // Whether vkGetQueryPoolResults for the range can be answered from captured values:
    // Ready now, Pending until an outstanding record arrives, or AskDevice.
    enum class Values { Ready, Pending, AskDevice };
    Values queryValues(uint64_t pool, uint32_t first, uint32_t count) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return queryValuesLocked(pool, first, count);
    }
    // Waits while queryValues() is Pending (a WAIT): until the records arrive or the feed ends.
    Values waitQueryValues(uint64_t pool, uint32_t first, uint32_t count) {
        std::unique_lock<decltype(mutex_)> lock(mutex_);
        Values values = Values::AskDevice;
        changed_.wait(lock, [&] { return (values = queryValuesLocked(pool, first, count)) != Values::Pending; });
        return values;
    }
    // vkGetQueryPoolResults from captured values: VK_SUCCESS, VK_NOT_READY, or
    // payloads::kAskDevice (nothing written) when the device must answer
    // (payloads::writeResults).
    int32_t queryResults(uint64_t pool, uint32_t first, uint32_t count, size_t dataSize, void* data, uint64_t stride,
                         uint32_t flags) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        if (lost_ || closed_ || !count || count > kMaxQueryRange || !capturedPools_.count(pool))
            return payloads::kAskDevice;
        auto queries = queryPools_.find(pool);
        if (queries == queryPools_.end()) return payloads::kAskDevice;
        return payloads::writeResults(count, dataSize, data, stride, flags, [&](uint32_t i) {
            payloads::Known known;
            auto query = queries->second.find(first + i);
            if (query == queries->second.end()) return known;
            if (query->second.state == QueryState::Available && query->second.known) {
                known.state = payloads::Known::Available;
                known.value = query->second.value;
            } else if (query->second.state == QueryState::Pending || query->second.state == QueryState::Reset) {
                known.state = payloads::Known::Unavailable;
            }
            return known;
        });
    }
    enum class Queries { Available, NotReady, AskDevice };
    // Whether every query of the range is available; AskDevice when any is not followed.
    Queries queries(uint64_t pool, uint32_t first, uint32_t count) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
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
        std::lock_guard<decltype(mutex_)> lock(mutex_);
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
        std::lock_guard<decltype(mutex_)> lock(mutex_);
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
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        static const char* const names[] = {"reset", "set", "untracked"};
        auto it = events_.find(event);
        std::string out = "event=";
        if (it == events_.end()) out += "unknown";
        else out += std::string(names[int(it->second.state)]) + " pending_batches=" + std::to_string(it->second.pending);
        return out + describeLocked();
    }
    std::string describeSemaphore(uint64_t semaphore) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        std::string out = "timeline=";
        if (it == semaphores_.end()) out += "unknown";
        else out += std::string(it->second.tracked ? "tracked" : "untracked") + " value=" +
                    std::to_string(it->second.value) + " pending=" + std::to_string(it->second.pending);
        return out + describeLocked();
    }

    // The completed value of a tracked timeline; false when untracked.
    bool timelineValue(uint64_t semaphore, uint64_t* value) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto it = semaphores_.find(semaphore);
        if (it == semaphores_.end() || !it->second.tracked) return false;
        *value = it->second.value;
        return true;
    }

    // --- Feed ---------------------------------------------------------------------------
    // A record from the feed stream. Unknown serials (already superseded) are ignored.
    void complete(uint64_t serial, int32_t status) { completeRecord(serial, status, nullptr, 0); }
    // A record and its payload (completion_payloads.h). Captured memory is stored in its
    // allocations' shadows, and the driver told of it (the flush shadow and write watch), before
    // the watch completes, so nothing that waits for the submission sees the shadow before or
    // writes it before the driver has noted it; the stored ranges are then delivered for the
    // invalidate after the wait (takeDelivered). A capture of memory a later batch also writes,
    // or whose watch an idle wait already completed, is not stored. A malformed payload is not
    // used, and the record still completes its watch.
    void completeRecord(uint64_t serial, int32_t status, const uint8_t* payload, size_t size) {
        std::vector<payloads::Capture> captures;
        if (status != kCompleted || !payload || !size || !payloads::parsePayload(payload, size, &captures))
            captures.clear();
        // The memory captures worth storing, and where they go: resolved without the lock.
        struct Store { uint64_t memory; MemoryTarget target; uint64_t offset, size; const uint8_t* data; };
        std::vector<Store> stores;
        // Shadows this record stores into, released (endDelivery) however this returns.
        struct Delivering {
            std::vector<MemoryTarget> targets;
            void push_back(const MemoryTarget& target) { targets.push_back(target); }
            ~Delivering() { for (const auto& target : targets) caboose::memory::writeWatch().endDelivery(target.base); }
        } delivering;
        const ResolveMemory resolve = resolve_.load(std::memory_order_acquire);
        if (resolve && !captures.empty()) {
            std::vector<std::pair<uint64_t, const payloads::Capture*>> wanted;
            {
                std::lock_guard<decltype(mutex_)> lock(mutex_);
                auto it = watches_.find(serial);
                if (it != watches_.end())
                    for (const auto& capture : captures) {
                        if (capture.entry.kind != payloads::kMemoryRange || capture.status != 0) continue;
                        const uint64_t memory = it->second.memoryKeyOf(capture.entry);
                        auto writer = memoryWriters_.find(memory);
                        if (memory && writer != memoryWriters_.end() && writer->second == serial)
                            wanted.push_back({memory, &capture});
                    }
            }
            for (const auto& [memory, capture] : wanted) {
                Store store{memory, {}, capture->entry.a, capture->entry.b, capture->data};
                if (!resolve(memory, &store.target) || !store.target.base || store.offset < store.target.begin ||
                    store.offset > store.target.end || store.size > store.target.end - store.offset)
                    continue;
                // Lazy blocks of the shadow (write_watch.h) are left as they are: their fill
                // reads the phone's copy, which holds these bytes. None becomes lazy meanwhile.
                caboose::memory::writeWatch().beginDelivery(store.target.base, store.offset, store.size,
                    [&](uint64_t begin, uint64_t end) {
                        stores.push_back(Store{memory, store.target, begin, end - begin,
                                               store.data + (begin - store.offset)});
                    });
                delivering.push_back(store.target);
            }
        }
        std::vector<Store> stored;
        {
            std::lock_guard<decltype(mutex_)> lock(mutex_);
            auto it = watches_.find(serial);
            if (it == watches_.end()) {
                // The record of a watch an idle wait completed: its queries' values.
                auto pending = valueWatches_.find(serial);
                if (pending == valueWatches_.end()) return;
                finishQueriesLocked(serial, status, pending->second, captures);
                releaseCapturesLocked(pending->second);
                valueWatches_.erase(pending);
                changed_.notify_all();
                return;
            }
            for (auto& store : stores) {
                auto writer = memoryWriters_.find(store.memory);
                if (writer == memoryWriters_.end() || writer->second != serial) continue;
                std::memcpy(store.target.base + store.offset, store.data, size_t(store.size));
                deliveredLocked(serial, store.memory, store.offset, store.size);
                stored.push_back(std::move(store));
            }
            if (stored.empty()) {
                Watch watch = std::move(it->second);
                watches_.erase(it);
                finishWatchLocked(serial, status, std::move(watch), captures, false);
                return;
            }
            storing_.insert(serial);
        }
        // Told without the lock (the hooks take locks above it), while the watch is outstanding.
        const StoredMemory note = stored_.load(std::memory_order_acquire);
        if (note)
            for (const auto& store : stored) note(store.memory, store.target, store.offset, store.size);
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        storing_.erase(serial);
        auto it = watches_.find(serial);
        if (it == watches_.end()) {  // a new executor connection forgot it
            changed_.notify_all();
            return;
        }
        Watch watch = std::move(it->second);
        watches_.erase(it);
        finishWatchLocked(serial, status, std::move(watch), captures, false);
    }
    // The ranges of `memory` the record of watch `serial` delivered into its shadow, once the
    // watch has completed: an invalidate after the wait need not read them. Each is handed out
    // once; false when the record delivered none of the allocation.
    bool takeDelivered(uint64_t memory, uint64_t serial, caboose::memory::gpu::Spans* out) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        auto found = delivered_.find({serial, memory});
        if (found == delivered_.end()) return false;
        *out = found->second;
        delivered_.erase(found);
        return true;
    }
    size_t deliveredEntries() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return delivered_.size();
    }
    size_t pendingValueRecords() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return valueWatches_.size();
    }

    // --- Speculation (hello 0x400000) -----------------------------------------------------
    // A wait the guest would block in may return at once for submissions whose completion the
    // process cannot observe except through the state this tracker reports: batches that write
    // no host-visible memory the guest refreshes, set, reset or wait for no event, end or reset
    // no query, and signal no fence or semaphore with an imported or exportable payload. Their
    // fences are reported signaled and their timelines reached as though their records had
    // arrived. Before the process's next command on its device stream, WAIT_SERIAL holds that
    // stream's decoding until each speculated watch has its record, so everything sent after
    // the wait reaches the GPU after the work it reported complete (docs/gpu-live.md,
    // "Completion feed"). Every watch on a queue completes behind the earlier ones there, so
    // a speculated watch takes every earlier watch of its queue with it, and the watches that
    // signal the timeline values its batches wait for; each of them must qualify, and none may
    // wait for anything the process has not yet sent (a timeline value no watch signals, an
    // event, a semaphore whose payload is imported): the stream it holds is how that would be
    // sent. A queue is speculated on once one of its watches had a record (so it is watched),
    // with at most `limit` speculated watches whose records are still to come. A record that
    // reports device loss is device loss, as for any watch; a value reported reached stays
    // reached. Waits that do not block (a zero timeout) are never speculated.
    // At most `limit` speculated watches per queue whose records are still to come; 0 turns
    // speculation off.
    void speculation(uint32_t limit) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        limit_ = limit;
    }
    // A semaphore whose payload is imported or may be exported: what waits for it or signals
    // it is never speculated.
    void semaphoreExternal(uint64_t semaphore) {
        if (!semaphore) return;
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        external_.insert(semaphore);
    }
    // A fence whose payload is imported or may be exported, until it is destroyed.
    void fenceExternal(uint64_t fence) {
        if (!fence) return;
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        externalFences_.insert(fence);
    }
    // A command buffer that waits for events: its batch may wait for a host vkSetEvent.
    void commandBufferWaitsEvents(uint64_t commandBuffer) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        commandWaits_.insert(commandBuffer);
    }
    // A submission (or sparse bind) no watch follows: the next watch of its queue completes
    // behind it, and is not speculated when this one waits for something not yet sent or
    // signals an external semaphore. Null `batch`: nothing is known of it.
    void unwatchedSubmission(uint64_t queue, const Batch* batch, const std::vector<uint64_t>& commandBuffers = {}) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        QueueState& state = queues_[queue];
        if (!batch) {
            state.open = state.tainted = true;
            return;
        }
        for (uint64_t cb : commandBuffers)
            if (commandWaits_.count(cb)) state.open = true;
        for (const auto& [semaphore, value] : batch->waits)
            if (!waitSentLocked(semaphore, value)) state.open = true;
        for (uint64_t semaphore : batch->signaled)
            if (external_.count(semaphore)) state.tainted = true;
    }
    // Whether a command on a device stream must first look at the speculated watches.
    bool speculating() const {
        return barriersPending_.load(std::memory_order_acquire) ||
               speculatedOutstanding_.load(std::memory_order_acquire) != 0;
    }
    // Before a command on device stream `stream`: the serials it sends WAIT_SERIAL for first,
    // when it is the stream the speculated watches went out on. Any other device stream first
    // waits until every speculated watch has its record (or the feed ended): the phone knows a
    // watch only once the stream that carries it has been decoded that far.
    std::vector<uint64_t> beforeCommand(uint64_t stream) {
        std::unique_lock<decltype(mutex_)> lock(mutex_);
        std::vector<uint64_t> serials;
        if (stream && stream == barrierStream_) {
            for (const auto& entry : barriers_) serials.push_back(entry.second);
            std::sort(serials.begin(), serials.end());
            barriers_.clear();
            barriersPending_.store(false, std::memory_order_release);
            return serials;
        }
        const Clock::time_point began = Clock::now();
        Clock::time_point report = began + stallFirst_;
        while (!changed_.wait_until(lock, report, [&] {
            return closed_ || !speculatedOutstanding_.load(std::memory_order_relaxed);
        })) {
            reportStallLocked("speculation-hold", began, "");
            report = Clock::now() + stallRepeat_;
        }
        return serials;
    }
    // Waits reported complete before their records arrived.
    uint64_t speculatedWaits() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return speculatedWaits_;
    }

private:
    struct Watch;
    void finishWatchLocked(uint64_t serial, int32_t status, Watch watch,
                           const std::vector<payloads::Capture>& captures, bool idle) {
        queueProgress_[watch.queue] = Clock::now();
        auto queue = queues_.find(watch.queue);
        if (watch.speculated) {
            speculatedOutstanding_.fetch_sub(1, std::memory_order_acq_rel);
            if (queue != queues_.end() && queue->second.speculated) --queue->second.speculated;
            // Its record is in: a stream need not hold behind it any more.
            auto barrier = barriers_.find(watch.queue);
            if (barrier != barriers_.end() && barrier->second == serial) barriers_.erase(barrier);
            if (barriers_.empty()) barriersPending_.store(false, std::memory_order_release);
        }
        // A record says whether the phone watches the queue; an idle wait says nothing of it.
        if (!idle && queue != queues_.end()) {
            if (status == kCompleted) queue->second.watchable = true;
            else if (status == kUnwatched) queue->second.watchable = false;
        }
        for (const auto& [event, set] : watch.events) {
            auto found = events_.find(event);
            if (found == events_.end()) continue;
            if (found->second.pending) --found->second.pending;
            if (status != kCompleted) found->second.state = EventState::Untracked;
            else if (found->second.state != EventState::Untracked)
                found->second.state = set ? EventState::Set : EventState::Reset;
        }
        for (const auto& entry : watch.memory) {
            auto writer = memoryWriters_.find(entry.first);
            if (writer != memoryWriters_.end() && writer->second == serial) memoryWriters_.erase(writer);
        }
        ValueWatch values{std::move(watch.queries), std::move(watch.entries), std::move(watch.keys)};
        if (idle && hasQueryEntries(values)) {
            // Completed, but the record with its queries' values is still to come: they stay
            // pending until then.
            valueWatches_[serial] = std::move(values);
        } else {
            finishQueriesLocked(serial, status, values, captures);
            releaseCapturesLocked(values);
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

public:
    // The executor is gone: every device of this process is lost.
    void loseAll() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        lost_ = true;
        closed_ = true;
        // Its streams ended: nothing is held behind the speculated watches any more.
        barriers_.clear();
        barriersPending_.store(false, std::memory_order_release);
        changed_.notify_all();
    }
    // A new executor connection after a loss: objects of the lost devices are asked about
    // on their own (ended) streams, which report device loss; new objects are tracked.
    void revive() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        for (auto& [handle, state] : fences_)
            if (state.state == Fence::Pending) { state.state = Fence::Untracked; state.serial = 0; }
        for (auto& [handle, state] : semaphores_) state.tracked = false;
        for (auto& [handle, state] : events_) state.state = EventState::Untracked;
        queryPools_.clear();
        capturedPools_.clear();
        valueWatches_.clear();
        poolCaptures_.clear();
        memoryWriters_.clear();
        delivered_.clear();
        commandQueries_.clear();
        watches_.clear();
        queues_.clear();
        queueProgress_.clear();
        barriers_.clear();
        barrierStream_ = 0;
        barriersPending_.store(false, std::memory_order_release);
        speculatedOutstanding_.store(0, std::memory_order_release);
        lost_ = false;
        lostDevices_.clear();
        closed_ = false;
        changed_.notify_all();
    }
    // The feed ended: nothing pending will be reported any more.
    void feedClosed() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        closed_ = true;
        changed_.notify_all();
    }
    bool deviceLost(uint64_t device = 0) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return lost_ || (device && lostDevices_.count(device));
    }

    // --- Queries and waits ---------------------------------------------------------------
    enum class Answer { Satisfied, NotYet, DeviceLost, AskDevice };
    // Fence status without waiting.
    Answer fencesSignaled(const uint64_t* fences, uint32_t count, bool all) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return fencesLocked(fences, count, all);
    }
    // A wait unsatisfied this long writes CABOOSE_GPU_WAIT_STALLED with what it waits for and
    // what the tracker knows of it, then again every stallRepeat: an application that waits for
    // the GPU forever says what for.
    void stallReports(Clock::duration first, Clock::duration repeat) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        stallFirst_ = first;
        stallRepeat_ = repeat;
    }
    // A wait of at least this long is the application's guard against a hung GPU, as DXVK's
    // five seconds per submission: it ends only after that long without the phone completing
    // work on the queues of the watches it waits for, and at the latest at the smaller of four
    // times its timeout and its timeout plus `ceiling`. Shorter waits end at their deadline.
    void progressTimeouts(Clock::duration atLeast, Clock::duration ceiling = std::chrono::seconds(30)) {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        progressAtLeast_ = atLeast;
        progressCeiling_ = ceiling;
    }
    // Waits until the fences are signaled (all, or any) or `deadline` passes.
    Answer waitFences(const uint64_t* fences, uint32_t count, bool all, Clock::time_point deadline) {
        std::unique_lock<decltype(mutex_)> lock(mutex_);
        bool tried = false;
        const Clock::time_point began = Clock::now();
        const Clock::duration requested = deadline - began;
        Clock::time_point report = began + stallFirst_;
        for (;;) {
            Answer answer = fencesLocked(fences, count, all);
            if (answer != Answer::NotYet) return answer;
            if (!tried && deadline > Clock::now() && speculateFencesLocked(fences, count, all)) continue;
            tried = true;
            if (closed_) return Answer::AskDevice;
            if (changed_.wait_until(lock, std::min(deadline, report)) == std::cv_status::timeout) {
                answer = fencesLocked(fences, count, all);
                if (answer == Answer::NotYet && progressingLocked(requested, began, [&](std::vector<uint64_t>* queues) {
                        for (uint32_t i = 0; i < count; ++i)
                            if (const uint64_t serial = fenceWatchLocked(fences[i])) queues->push_back(watches_.at(serial).queue);
                    }, &deadline))
                    continue;
                if (answer == Answer::NotYet && !closed_ && Clock::now() < deadline) {
                    std::string what;
                    for (uint32_t i = 0; i < count; ++i) {
                        auto it = fences_.find(fences[i]);
                        static const char* const names[] = {"unsignaled", "signaled", "pending", "untracked"};
                        what += " fence" + std::to_string(i) + "=" + (it == fences_.end() ? "unknown" : names[int(it->second.state)]);
                        if (it != fences_.end() && it->second.serial)
                            what += "/serial" + std::to_string(it->second.serial) +
                                    (watches_.count(it->second.serial) ? "/outstanding" : "/answered");
                    }
                    reportStallLocked("vkWaitForFences", began, what);
                    report = Clock::now() + stallRepeat_;
                    continue;
                }
                return answer == Answer::NotYet && closed_ ? Answer::AskDevice : answer;
            }
        }
    }
    // Waits until the timelines reach their values (all, or any) or `deadline` passes.
    Answer waitTimelines(const uint64_t* semaphores, const uint64_t* values, uint32_t count, bool all,
                         Clock::time_point deadline) {
        std::unique_lock<decltype(mutex_)> lock(mutex_);
        bool tried = false;
        const Clock::time_point began = Clock::now();
        const Clock::duration requested = deadline - began;
        Clock::time_point report = began + stallFirst_;
        for (;;) {
            Answer answer = timelinesLocked(semaphores, values, count, all);
            if (answer != Answer::NotYet) return answer;
            if (!tried && deadline > Clock::now() && speculateTimelinesLocked(semaphores, values, count, all)) continue;
            tried = true;
            if (closed_) return Answer::AskDevice;
            if (changed_.wait_until(lock, std::min(deadline, report)) == std::cv_status::timeout) {
                answer = timelinesLocked(semaphores, values, count, all);
                if (answer == Answer::NotYet && progressingLocked(requested, began, [&](std::vector<uint64_t>* queues) {
                        for (uint32_t i = 0; i < count; ++i)
                            if (const uint64_t serial = providerLocked(semaphores[i], values[i]))
                                queues->push_back(watches_.at(serial).queue);
                    }, &deadline))
                    continue;
                if (answer == Answer::NotYet && !closed_ && Clock::now() < deadline) {
                    std::string what;
                    for (uint32_t i = 0; i < count; ++i) {
                        auto it = semaphores_.find(semaphores[i]);
                        what += " semaphore" + std::to_string(i) + "=0x";
                        char key[24];
                        std::snprintf(key, sizeof key, "%llx", (unsigned long long)semaphores[i]);
                        what += key;
                        what += " wanted=" + std::to_string(values[i]);
                        if (it == semaphores_.end()) what += " unknown";
                        else what += std::string(it->second.tracked ? " tracked" : " untracked") + " value=" +
                                     std::to_string(it->second.value) + " pending=" + std::to_string(it->second.pending);
                    }
                    reportStallLocked("vkWaitSemaphores", began, what);
                    report = Clock::now() + stallRepeat_;
                    continue;
                }
                return answer == Answer::NotYet && closed_ ? Answer::AskDevice : answer;
            }
        }
    }
    size_t pendingWatches() {
        std::lock_guard<decltype(mutex_)> lock(mutex_);
        return watches_.size();
    }

private:
    uint64_t outstandingFromLocked() const {
        if (closed_) return UINT64_MAX;
        uint64_t oldest = lastSerial_ + 1;
        for (const auto& entry : watches_) oldest = std::min(oldest, entry.first);
        return oldest;
    }
    // At a long wait's deadline: whether it goes on because what it waits for is watched and the
    // phone completed work on one of those watches' queues within the last `requested`; then
    // `deadline` moves to `requested` after that completion, but never past the ceiling: the
    // smaller of four times `requested` and `requested` plus thirty seconds after `began`, so an
    // application's hang detection still fires behind a queue that keeps completing other work.
    template <class Queues>
    bool progressingLocked(Clock::duration requested, Clock::time_point began, Queues&& queuesOf,
                           Clock::time_point* deadline) {
        const Clock::time_point now = Clock::now();
        if (now < *deadline || closed_ || lost_ || requested < progressAtLeast_) return false;
        const Clock::time_point ceiling = began + std::min(4 * requested, requested + progressCeiling_);
        if (now >= ceiling) return false;
        std::vector<uint64_t> queues;
        queuesOf(&queues);
        Clock::time_point last{};
        for (uint64_t queue : queues) {
            auto progress = queueProgress_.find(queue);
            if (progress != queueProgress_.end()) last = std::max(last, progress->second);
        }
        if (queues.empty() || last + requested <= now) return false;
        *deadline = std::min(last + requested, ceiling);
        ++extendedWaits_;
        return true;
    }
    void reportStallLocked(const char* call, Clock::time_point began, const std::string& what) const {
        const long long seconds = (long long)std::chrono::duration_cast<std::chrono::seconds>(Clock::now() - began).count();
        std::fprintf(stderr, "CABOOSE_GPU_WAIT_STALLED call=%s seconds=%lld%s%s\n", call, seconds, what.c_str(),
                     describeLocked().c_str());
        std::fflush(stderr);
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
        if (extendedWaits_) out += " extended_waits=" + std::to_string(extendedWaits_);
        if (const uint64_t held = speculatedOutstanding_.load(std::memory_order_relaxed))
            out += " speculated_outstanding=" + std::to_string(held);
        if (barriersPending_.load(std::memory_order_relaxed))
            out += " barriers=" + std::to_string(barriers_.size()) + " barrier_stream=" + std::to_string(barrierStream_);
        // Tracked timelines a submitted signal is still ahead of: with no watch outstanding,
        // their value is behind what the device reached.
        size_t behind = 0;
        std::string listed;
        for (const auto& [semaphore, state] : semaphores_) {
            if (!state.tracked || state.pending <= state.value) continue;
            if (++behind > 4) continue;
            char item[96];
            std::snprintf(item, sizeof item, "%s0x%llx:%llu/%llu", listed.empty() ? "" : ",",
                          (unsigned long long)semaphore, (unsigned long long)state.value,
                          (unsigned long long)state.pending);
            listed += item;
        }
        if (behind) out += " timelines_behind=" + std::to_string(behind) + " [" + listed + "]";
        // Other threads' waits of five seconds or more (WaitTimer): what may hold this one.
        out += waitsInProgress().older(std::chrono::seconds(5));
        return out;
    }
    struct FenceState { Fence state = Fence::Unsignaled; uint64_t serial = 0; uint64_t device = 0; };
    struct SemaphoreState { bool tracked = false; uint64_t value = 0; uint64_t pending = 0; uint64_t device = 0; };
    struct Watch {
        uint64_t fence = 0, queue = 0, device = 0;
        // Speculation: whether its batch waits for nothing the process has not sent (closed)
        // and has no effect beyond its fence and timelines (speculable); whether a wait was
        // reported complete before its record; the stream its watch went out on; the timeline
        // values its batches wait for that were not reached when it was sent; whether its
        // command buffers wait for events.
        bool closed = false, speculable = false, speculated = false, waitsEvents = false;
        uint64_t stream = 0;
        std::vector<std::pair<uint64_t, uint64_t>> waits;
        std::vector<std::pair<uint64_t, uint64_t>> signals;
        std::vector<std::pair<uint64_t, bool>> events;  // set (true) or reset, in order
        std::vector<std::pair<uint64_t, uint32_t>> queries;  // (pool, index) ended in the batch
        // COMPLETION_WATCH2 entries, and the guest key of each one's pool or allocation.
        std::vector<payloads::Entry> entries;
        std::vector<uint64_t> keys;
        std::vector<std::pair<uint64_t, uint64_t>> memory;  // (allocation, serial) it writes
        uint64_t memoryKeyOf(const payloads::Entry& entry) const {
            for (size_t i = 0; i < entries.size(); ++i)
                if (entries[i] == entry && entry.kind == payloads::kMemoryRange) return keys[i];
            return 0;
        }
    };
    // A query as the process knows it. Reset: reset and not ended since (never available).
    struct QueryState {
        enum State { Reset, Pending, Available, Untracked } state = Reset;
        uint64_t serial = 0;  // the watch of the batch that ends it, while Pending
        bool known = false;   // Available with the value the phone captured
        uint64_t value = 0;
    };
    static QueryState untrackedQuery() {
        QueryState state;
        state.state = QueryState::Untracked;
        return state;
    }
    // The queries of a completed watch whose record, with their values, is still to come.
    struct ValueWatch {
        std::vector<std::pair<uint64_t, uint32_t>> queries;
        std::vector<payloads::Entry> entries;
        std::vector<uint64_t> keys;
    };
    static bool hasQueryEntries(const ValueWatch& watch) {
        for (const auto& entry : watch.entries)
            if (entry.kind == payloads::kQueryRange) return true;
        return false;
    }
    // Bounded by the watches outstanding: the phone writes a record for each.
    std::map<uint64_t, ValueWatch> valueWatches_;
    struct CapturedPool { uint64_t handle, device; };
    std::unordered_map<uint64_t, CapturedPool> capturedPools_;
    std::unordered_map<uint64_t, uint32_t> poolCaptures_;    // pool -> watches capturing it
    void releaseCapturesLocked(const ValueWatch& watch) {
        for (size_t i = 0; i < watch.entries.size(); ++i) {
            if (watch.entries[i].kind != payloads::kQueryRange) continue;
            auto found = poolCaptures_.find(watch.keys[i]);
            if (found != poolCaptures_.end() && !--found->second) poolCaptures_.erase(found);
        }
    }
    std::unordered_map<uint64_t, uint64_t> memoryWriters_;   // allocation -> its latest writing serial
    // (serial, allocation) -> the ranges its record stored, until an invalidate takes them. Only
    // ranges held exactly: one the spans cannot hold is left out, and read back by the
    // invalidate. At most kMaxDelivered allocations' worth, the oldest serials going first.
    static constexpr size_t kMaxDelivered = 4096;
    std::map<std::pair<uint64_t, uint64_t>, caboose::memory::gpu::Spans> delivered_;
    void deliveredLocked(uint64_t serial, uint64_t memory, uint64_t offset, uint64_t size) {
        if (!size || offset + size < offset) return;
        delivered_[{serial, memory}].addExactly(offset, offset + size);
        while (delivered_.size() > kMaxDelivered) delivered_.erase(delivered_.begin());
    }
    // Serials whose record is noting its stored captures; their watches complete after.
    std::unordered_set<uint64_t> storing_;
    std::atomic<ResolveMemory> resolve_{nullptr};
    std::atomic<StoredMemory> stored_{nullptr};
    // The batch's captures, within one record: its ended queries of captured pools as ranges,
    // then its memory writes, while entries and payload bytes last. Every allocation it
    // writes records it as the latest writer, captured or not.
    void requestLocked(uint64_t serial, Watch& watch, const Captures& captures) {
        uint64_t payload = 0;
        auto add = [&](const payloads::Entry& entry, uint64_t key) {
            const uint64_t bytes = payloads::captureSize(entry);
            if (watch.entries.size() >= payloads::kMaxEntries || bytes > payloads::kMaxPayload - payload)
                return false;
            payload += bytes;
            watch.entries.push_back(entry);
            watch.keys.push_back(key);
            return true;
        };
        std::vector<std::pair<uint64_t, uint32_t>> ended;
        for (const auto& query : watch.queries) {
            auto pool = capturedPools_.find(query.first);
            if (pool != capturedPools_.end() && pool->second.device == watch.device) ended.push_back(query);
        }
        std::sort(ended.begin(), ended.end());
        ended.erase(std::unique(ended.begin(), ended.end()), ended.end());
        for (size_t i = 0; i < ended.size();) {
            size_t j = i + 1;
            while (j < ended.size() && ended[j].first == ended[i].first &&
                   uint64_t(ended[j].second) == uint64_t(ended[j - 1].second) + 1) ++j;
            if (!add({payloads::kQueryRange, capturedPools_[ended[i].first].handle, ended[i].second, j - i},
                     ended[i].first)) break;
            ++poolCaptures_[ended[i].first];
            i = j;
        }
        for (const auto& write : captures.memory) {
            if (!write.memory || !write.handle || !write.size) continue;
            memoryWriters_[write.memory] = serial;
            watch.memory.push_back({write.memory, serial});
            add({payloads::kMemoryRange, write.handle, write.offset, write.size}, write.memory);
        }
    }
    // The queries the batch `serial` ended: available (with the value its record captured)
    // when it completed, asked on the device otherwise. A query reset or ended again since
    // is left alone.
    void finishQueriesLocked(uint64_t serial, int32_t status, const ValueWatch& watch,
                             const std::vector<payloads::Capture>& captures) {
        if (status == kCompleted) {
            for (const auto& capture : captures) {
                if (capture.entry.kind != payloads::kQueryRange || (capture.status != 0 && capture.status != 1))
                    continue;
                uint64_t poolKey = 0;
                for (size_t i = 0; i < watch.entries.size(); ++i)
                    if (watch.entries[i] == capture.entry) poolKey = watch.keys[i];
                auto pool = queryPools_.find(poolKey);
                if (!poolKey || pool == queryPools_.end()) continue;
                for (uint64_t q = 0; q < capture.entry.b; ++q) {
                    uint64_t pair[2];
                    std::memcpy(pair, capture.data + q * 16, 16);
                    auto query = pool->second.find(uint32_t(capture.entry.a + q));
                    if (query == pool->second.end() || query->second.state != QueryState::Pending ||
                        query->second.serial != serial || pair[1] != 1) continue;
                    query->second.value = pair[0];
                    query->second.known = true;
                }
            }
        }
        for (const auto& [poolHandle, index] : watch.queries) {
            auto pool = queryPools_.find(poolHandle);
            if (pool == queryPools_.end()) continue;
            auto query = pool->second.find(index);
            if (query == pool->second.end() || query->second.state != QueryState::Pending ||
                query->second.serial != serial) continue;
            query->second.state = status == kCompleted ? QueryState::Available : QueryState::Untracked;
            if (status != kCompleted) query->second.known = false;
            query->second.serial = 0;
        }
    }
    Values queryValuesLocked(uint64_t pool, uint32_t first, uint32_t count) const {
        if (lost_ || closed_ || !count || count > kMaxQueryRange || !capturedPools_.count(pool))
            return Values::AskDevice;
        auto queries = queryPools_.find(pool);
        if (queries == queryPools_.end()) return Values::AskDevice;
        bool pending = false;
        for (uint32_t i = 0; i < count; ++i) {
            auto query = queries->second.find(first + i);
            if (query == queries->second.end()) return Values::AskDevice;
            if (query->second.state == QueryState::Pending) pending = true;
            else if (query->second.state != QueryState::Available || !query->second.known) return Values::AskDevice;
        }
        return pending ? Values::Pending : Values::Ready;
    }
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

    // --- Speculation state ---------------------------------------------------------------
    struct QueueState {
        bool watchable = false;   // a record of one of its watches arrived
        bool open = false;        // an unwatched submission since its last watch waits for something unsent
        bool tainted = false;     // ... or signals an external semaphore
        uint32_t speculated = 0;  // speculated watches whose records are still to come
    };
    std::unordered_map<uint64_t, QueueState> queues_;
    std::unordered_set<uint64_t> external_, externalFences_;
    std::unordered_set<uint64_t> commandWaits_;
    uint32_t limit_ = 0;
    // The latest speculated serial of each queue not yet held behind on the barrier stream.
    std::unordered_map<uint64_t, uint64_t> barriers_;
    uint64_t barrierStream_ = 0;
    std::atomic<bool> barriersPending_{false};
    std::atomic<uint64_t> speculatedOutstanding_{0};
    Clock::duration stallFirst_ = std::chrono::seconds(10), stallRepeat_ = std::chrono::seconds(60);
    Clock::duration progressAtLeast_ = std::chrono::seconds(1);
    Clock::duration progressCeiling_ = std::chrono::seconds(30);
    std::unordered_map<uint64_t, Clock::time_point> queueProgress_;  // last record of each queue
    uint64_t extendedWaits_ = 0;
    uint64_t speculatedWaits_ = 0;

    // Whether a wait for `value` of `semaphore` (a binary semaphore when it is no followed
    // timeline) depends only on what was sent: a followed timeline already there or signaled
    // by an outstanding watch, or a binary semaphore whose payload is the process's own, whose
    // signal Vulkan requires to have been submitted before the wait.
    bool waitSentLocked(uint64_t semaphore, uint64_t value) const {
        if (external_.count(semaphore)) return false;
        auto it = semaphores_.find(semaphore);
        if (it == semaphores_.end()) return true;
        if (!it->second.tracked) return false;
        return it->second.value >= value || providerLocked(semaphore, value) != 0;
    }
    // The first outstanding watch that signals `semaphore` to at least `value`; 0 when none.
    uint64_t providerLocked(uint64_t semaphore, uint64_t value) const {
        uint64_t best = 0;
        for (const auto& [serial, watch] : watches_)
            for (const auto& [signaled, to] : watch.signals)
                if (signaled == semaphore && to >= value && (!best || serial < best)) best = serial;
        return best;
    }
    void classifyLocked(Watch& watch, const Batch& batch, bool effectsFollowed) {
        QueueState& queue = queues_[watch.queue];
        bool closed = !queue.open && !watch.waitsEvents, followed = effectsFollowed && !queue.tainted;
        queue.open = queue.tainted = false;  // this watch completes behind them: it carries them
        for (const auto& [semaphore, value] : batch.waits) {
            if (external_.count(semaphore)) {
                closed = false;
                continue;
            }
            auto it = semaphores_.find(semaphore);
            if (it == semaphores_.end()) continue;
            if (!it->second.tracked) closed = false;
            else if (it->second.value < value) watch.waits.push_back({semaphore, value});
        }
        for (uint64_t semaphore : batch.signaled) {
            auto it = semaphores_.find(semaphore);
            if (external_.count(semaphore) || (it != semaphores_.end() && !it->second.tracked)) followed = false;
        }
        watch.closed = closed;
        watch.stream = batch.stream;
        watch.speculable = closed && followed && batch.stream && watch.queue && !batch.hostWrites &&
                           watch.events.empty() && watch.queries.empty() && watch.entries.empty() &&
                           watch.memory.empty();
    }
    // Adds to `out` the watches that complete no later than `serial` and are not yet
    // speculated: it, every earlier outstanding watch of its queue, and (in turn) the watches
    // that signal the timeline values those wait for. False when one of them may not be
    // speculated, or would hold another stream than `stream` (0: none yet).
    bool closureLocked(uint64_t serial, std::vector<uint64_t>* out, uint64_t* stream) const {
        std::vector<uint64_t> todo{serial};
        while (!todo.empty()) {
            const uint64_t next = todo.back();
            todo.pop_back();
            if (std::find(out->begin(), out->end(), next) != out->end()) continue;
            auto it = watches_.find(next);
            if (it == watches_.end() || it->second.speculated) continue;  // its record arrived, or held already
            const Watch& watch = it->second;
            if (!watch.speculable || (*stream && watch.stream != *stream)) return false;
            *stream = watch.stream;
            out->push_back(next);
            for (const auto& [other, earlier] : watches_)
                if (other < next && earlier.queue == watch.queue && !earlier.speculated) todo.push_back(other);
            for (const auto& [semaphore, value] : watch.waits) {
                auto state = semaphores_.find(semaphore);
                if (state == semaphores_.end() || !state->second.tracked) return false;
                if (state->second.value >= value) continue;
                const uint64_t provider = providerLocked(semaphore, value);
                if (!provider) return false;
                todo.push_back(provider);
            }
        }
        return true;
    }
    // Reports complete the watches `serials` need, when every one may be speculated within the
    // limit; whether it did.
    bool speculateLocked(const std::vector<uint64_t>& serials) {
        if (!limit_ || lost_ || closed_ || serials.empty()) return false;
        // While earlier speculation is held on a stream, more is held on the same one.
        uint64_t stream = barriersPending_.load(std::memory_order_relaxed) ||
                                  speculatedOutstanding_.load(std::memory_order_relaxed)
                              ? barrierStream_
                              : 0;
        std::vector<uint64_t> closure;
        for (uint64_t serial : serials)
            if (!closureLocked(serial, &closure, &stream)) return false;
        if (closure.empty() || !stream) return false;
        std::unordered_map<uint64_t, uint32_t> perQueue;
        for (uint64_t serial : closure) {
            const Watch& watch = watches_.at(serial);
            if (watch.device && lostDevices_.count(watch.device)) return false;
            auto queue = queues_.find(watch.queue);
            if (queue == queues_.end() || !queue->second.watchable ||
                queue->second.speculated + ++perQueue[watch.queue] > limit_)
                return false;
        }
        for (uint64_t serial : closure) {
            Watch& watch = watches_.at(serial);
            watch.speculated = true;
            ++queues_[watch.queue].speculated;
            speculatedOutstanding_.fetch_add(1, std::memory_order_acq_rel);
            uint64_t& barrier = barriers_[watch.queue];
            barrier = std::max(barrier, serial);
            if (watch.fence) {
                auto fence = fences_.find(watch.fence);
                if (fence != fences_.end() && fence->second.state == Fence::Pending && fence->second.serial == serial) {
                    fence->second.state = Fence::Signaled;
                    fence->second.serial = 0;
                }
            }
            for (const auto& [semaphore, value] : watch.signals) {
                auto state = semaphores_.find(semaphore);
                if (state != semaphores_.end() && state->second.tracked)
                    state->second.value = std::max(state->second.value, value);
            }
        }
        barrierStream_ = stream;
        barriersPending_.store(true, std::memory_order_release);
        ++speculatedWaits_;
        changed_.notify_all();
        return true;
    }
    // The outstanding watch a pending fence waits for; 0 when there is none.
    uint64_t fenceWatchLocked(uint64_t fence) const {
        auto it = fences_.find(fence);
        if (it == fences_.end() || it->second.state != Fence::Pending || !watches_.count(it->second.serial)) return 0;
        return it->second.serial;
    }
    bool speculateFencesLocked(const uint64_t* fences, uint32_t count, bool all) {
        if (!limit_) return false;
        std::vector<uint64_t> serials;
        for (uint32_t i = 0; i < count; ++i) {
            auto it = fences_.find(fences[i]);
            if (it != fences_.end() && it->second.state == Fence::Signaled) continue;
            const uint64_t serial = fenceWatchLocked(fences[i]);
            if (!all) {
                if (serial && speculateLocked({serial})) return true;
                continue;
            }
            if (!serial) return false;
            serials.push_back(serial);
        }
        return all && speculateLocked(serials);
    }
    bool speculateTimelinesLocked(const uint64_t* semaphores, const uint64_t* values, uint32_t count, bool all) {
        if (!limit_) return false;
        std::vector<uint64_t> serials;
        for (uint32_t i = 0; i < count; ++i) {
            auto it = semaphores_.find(semaphores[i]);
            if (it == semaphores_.end() || !it->second.tracked) return false;
            if (it->second.value >= values[i]) continue;
            const uint64_t serial = providerLocked(semaphores[i], values[i]);
            if (!all) {
                if (serial && speculateLocked({serial})) return true;
                continue;
            }
            if (!serial) return false;
            serials.push_back(serial);
        }
        return all && speculateLocked(serials);
    }

    caboose::lock_order::Mutex<std::mutex, caboose::lock_order::kCompletion> mutex_;
    std::condition_variable_any changed_;
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

// Reads one record of the feed stream with recv(data, size) (true once all of it arrived) and
// applies it to `tracker`: the 16-byte head (serial, status, payload bytes, which a phone
// without completion payloads sends as 0) and its payload. A record with serial 0 is not a
// completion: a FAULT (status payloads::kFaultStatus with an 8-byte payload, the failed
// command's opcode u32 and result i32; docs/gpu-live.md, "Silent success") is handed to
// onFault(opcode, result), and any other is skipped. False when the stream ended, or a record
// announces more than one may carry, which ends the feed.
template <class Recv, class OnFault> inline bool readRecord(Recv recv, Tracker& tracker, OnFault onFault) {
    uint8_t head[payloads::kRecordHeadSize];
    if (!recv(head, sizeof(head))) return false;
    uint64_t serial;
    int32_t status;
    uint32_t bytes;
    std::memcpy(&serial, head, 8);
    std::memcpy(&status, head + 8, 4);
    std::memcpy(&bytes, head + 12, 4);
    if (bytes > payloads::kMaxPayload) return false;
    thread_local std::vector<uint8_t> payload;
    payload.resize(bytes);
    if (bytes && !recv(payload.data(), bytes)) return false;
    if (serial) {
        tracker.completeRecord(serial, status, payload.data(), bytes);
    } else if (status == payloads::kFaultStatus && bytes == 8) {
        uint32_t opcode;
        int32_t result;
        std::memcpy(&opcode, payload.data(), 4);
        std::memcpy(&result, payload.data() + 4, 4);
        onFault(opcode, result);
    }
    return true;
}
template <class Recv> inline bool readRecord(Recv recv, Tracker& tracker) {
    return readRecord(recv, tracker, [](uint32_t, int32_t) {});
}

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
    uint64_t id = waitsInProgress().begin(what);
    ~WaitTimer() {
        waitsInProgress().end(id);
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
// Replies this thread read from a stream whose executor was gone (SocketStream's lost reply).
// An encoder call notes the count at entry: a call whose reply was lost on the way gives the
// stand-in outputs a call made after the loss gets (handles, support, sizes), not the lost
// reply's words. With CABOOSE_GPU_ON_LOSS=quiet those words are zeros, which read as a null
// handle or "unsupported": Zink, creating a descriptor set layout as its executor left, got
// a null layout and crashed the compositor.
inline thread_local uint64_t lostReplies = 0;
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
// What an executor's loss ends at once: connections of the process's own beside the device
// stream (lazy readback's fills, write_watch.h) register here, so nothing waits on an executor
// that is gone. Hooks run on the thread that saw the loss, after it is marked.
inline std::vector<GenerationHook>& lossHooks() {
    static auto* instance = new std::vector<GenerationHook>;
    return *instance;
}
inline bool onExecutorLost(GenerationHook hook) {
    std::lock_guard<std::mutex> lock(generationHooksMutex());
    lossHooks().push_back(hook);
    return true;
}
inline void markExecutorLost() {
    if (executorLost.exchange(true, std::memory_order_acq_rel)) return;
    executorGeneration.fetch_add(1, std::memory_order_acq_rel);
    lostSocketInode.store(socketInode());
    std::fprintf(stderr, "CABOOSE_GPU_EXECUTOR_LOST\n");
    tracker().loseAll();
    std::vector<GenerationHook> hooks;
    {
        std::lock_guard<std::mutex> hooksLock(generationHooksMutex());
        hooks = lossHooks();
    }
    for (GenerationHook hook : hooks) hook();
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
