// SPDX-License-Identifier: MIT
#pragma once

// Status polls that never change (CABOOSE_GPU_POLL_STALLED). A game that spins on a fence,
// query or timeline whose state never changes freezes with no error anywhere: the status
// is answered locally (the completion feed's tracker) or the device keeps answering
// "not ready". Once the same object has been polled without changing for 10 seconds, one
// line names the call, the object, how long and how often, and what the driver knows of
// it; again every minute while it lasts.

#include <chrono>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <utility>

namespace caboose::memory {

class PollStall {
public:
    using Clock = std::function<uint64_t()>;  // milliseconds
    static constexpr uint64_t stalledMs = 10000, repeatMs = 60000;
    static constexpr size_t maxObjects = 4096;

    explicit PollStall(Clock clock = steadyMs,
                       std::function<void(const std::string&)> log = [](const std::string& line) {
                           std::fprintf(stderr, "%s\n", line.c_str());
                       })
        : clock_(std::move(clock)), log_(std::move(log)) {}

    // A poll of `object` by `call` found it ready (or changed) or not. `describe()` says what
    // the driver knows of the object; it is called only when a line is written.
    template <class Describe>
    void poll(const char* call, uint64_t object, bool ready, Describe&& describe) {
        std::string line;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const auto key = std::make_pair(call, object);
            if (ready) {
                entries_.erase(key);
                return;
            }
            const uint64_t now = clock_();
            auto found = entries_.find(key);
            if (found == entries_.end()) {
                if (entries_.size() >= maxObjects) entries_.erase(entries_.begin());
                entries_.emplace(key, Entry{now, 0, 1});
                return;
            }
            Entry& entry = found->second;
            ++entry.polls;
            if (now - entry.first < stalledMs || (entry.logged && now - entry.logged < repeatMs)) return;
            entry.logged = now;
            char head[160];
            std::snprintf(head, sizeof(head), "CABOOSE_GPU_POLL_STALLED call=%s object=0x%" PRIx64 " seconds=%" PRIu64 " polls=%" PRIu64 " ",
                          call, object, (now - entry.first) / 1000, entry.polls);
            line = head;
        }
        line += describe();
        log_(line);
    }
    // A poll of a value (a timeline semaphore's counter): unchanged counts as not ready.
    template <class Describe>
    void value(const char* call, uint64_t object, uint64_t current, Describe&& describe) {
        bool changed;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto& last = values_[std::make_pair(call, object)];
            changed = last.first == false || last.second != current;
            last = {true, current};
            if (values_.size() > maxObjects) values_.erase(values_.begin());
        }
        poll(call, object, changed, std::forward<Describe>(describe));
    }

private:
    struct Entry {
        uint64_t first, logged, polls;
    };
    static uint64_t steadyMs() {
        return uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
    }
    Clock clock_;
    std::function<void(const std::string&)> log_;
    std::mutex mutex_;
    std::map<std::pair<const char*, uint64_t>, Entry> entries_;
    std::map<std::pair<const char*, uint64_t>, std::pair<bool, uint64_t>> values_;
};

inline PollStall& pollStall() {
    static PollStall instance;
    return instance;
}

}  // namespace caboose::memory
