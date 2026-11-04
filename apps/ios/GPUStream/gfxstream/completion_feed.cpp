// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "completion_feed.h"

#include <chrono>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <system_error>
#include <unistd.h>
#include <vector>

namespace caboose::gpuv2 {
namespace {
uint32_t u32(const unsigned char* p) { uint32_t v; std::memcpy(&v, p, 4); return v; }
uint64_t u64(const unsigned char* p) { uint64_t v; std::memcpy(&v, p, 8); return v; }

int sendAll(int fd, const unsigned char* data, size_t size) {
    while (size) {
#ifdef MSG_NOSIGNAL
        ssize_t sent = send(fd, data, size, MSG_NOSIGNAL);
#else
        ssize_t sent = send(fd, data, size, 0);  // the descriptor carries SO_NOSIGPIPE
#endif
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return sent == 0 ? EPIPE : errno;
        data += sent;
        size -= static_cast<size_t>(sent);
    }
    return 0;
}
}  // namespace

bool CompletionFeed::parseWatch(const unsigned char* packet, size_t size, uint64_t* queue, uint64_t* serial) {
    if (size != kWatchPacketSize || u32(packet) != kWatchOpcode || u32(packet + 4) != kWatchPacketSize)
        return false;
    *queue = u64(packet + 8);
    *serial = u64(packet + 16);
    return *queue != 0 && *serial != 0;
}

bool CompletionFeed::parseOrder(const unsigned char* packet, size_t size, uint64_t* serial) {
    if (size != kOrderPacketSize || u32(packet) != kOrderOpcode || u32(packet + 4) != kOrderPacketSize)
        return false;
    *serial = u64(packet + 8);
    return *serial != 0;
}

void CompletionFeed::ordered(uint64_t serial) {
    {
        std::lock_guard<std::mutex> lock(orderMutex_);
        if (serial <= ordered_) return;
        ordered_ = serial;
    }
    orderChanged_.notify_all();
}

int CompletionFeed::waitOrdered(uint64_t serial) {
    std::unique_lock<std::mutex> lock(orderMutex_);
    orderChanged_.wait(lock, [&] { return ordersCancelled_ || ordered_ >= serial; });
    return ordered_ >= serial ? 0 : ECANCELED;
}

void CompletionFeed::cancelOrders() {
    {
        std::lock_guard<std::mutex> lock(orderMutex_);
        ordersCancelled_ = true;
    }
    orderChanged_.notify_all();
}

bool CompletionFeed::parseFeed(const unsigned char* packet, size_t size) {
    return size == kFeedPacketSize && u32(packet) == kFeedOpcode && u32(packet + 4) == kFeedPacketSize &&
           u32(packet + 8) == kFeedVersion && u32(packet + 12) == 0;
}

int64_t CompletionFeed::nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

CompletionFeed::State CompletionFeed::state() {
    State s;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        s.watches = watches_;
        s.unwatched = unwatched_;
        s.outstanding = outstanding_;
        s.lanes = lanes_.size();
        // The marker watched longest ago over every lane: the front of each lane's order.
        const Pending* oldest = nullptr;
        for (const auto& lane : lanes_) {
            const Pending* front = lane->waiting.serial ? &lane->waiting
                                   : lane->markers.empty() ? nullptr : &lane->markers.front();
            if (front && (!oldest || front->watchedMs < oldest->watchedMs ||
                          (front->watchedMs == oldest->watchedMs && front->serial < oldest->serial)))
                oldest = front;
        }
        if (oldest) {
            s.oldestSerial = oldest->serial;
            s.oldestQueue = oldest->queue;
            s.oldestWatchedMs = oldest->watchedMs;
        }
        s.lastCompletedSerial = lastCompletedSerial_;
        s.lastStatus = lastStatus_;
        s.lastCompletedMs = lastCompletedMs_;
        s.lastWrittenSerial = lastWrittenSerial_;
        s.lastWrittenMs = lastWrittenMs_;
        s.unwritten = records_.size();
        s.feedAttached = attached_;
    }
    std::lock_guard<std::mutex> lock(orderMutex_);
    s.ordered = ordered_;
    return s;
}

CompletionFeed::CompletionFeed(Submit submit) : submit_(std::move(submit)) {
    if (pipe(wake_) != 0) throw std::system_error(errno, std::generic_category(), "completion feed pipe");
    for (int fd : wake_) {
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    }
}

CompletionFeed::~CompletionFeed() {
    close();
    for (int fd : wake_) if (fd >= 0) ::close(fd);
}

void CompletionFeed::close() {
    cancelOrders();
    std::vector<std::thread*> threads;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        closing_ = true;
        // No lane is made once closing: this is every thread there will be.
        for (auto& lane : lanes_) {
            lane->changed.notify_all();
            threads.push_back(&lane->thread);
        }
    }
    for (std::thread* thread : threads)
        if (thread->joinable() && thread->get_id() != std::this_thread::get_id()) thread->join();
}

CompletionFeed::Lane& CompletionFeed::laneForLocked(uint64_t queue) {
    auto found = laneOfQueue_.find(queue);
    if (found != laneOfQueue_.end()) return *lanes_[found->second];
    if (lanes_.size() < kMaxLanes) {
        lanes_.push_back(std::make_unique<Lane>());
        Lane& lane = *lanes_.back();
        lane.thread = std::thread([this, &lane] { watcherLoop(lane); });
        laneOfQueue_.emplace(queue, lanes_.size() - 1);
        return lane;
    }
    // Every lane is taken: the marker joins the lane with the fewest markers. A queue's
    // markers may then wait in different lanes; records may arrive in any order.
    Lane* least = lanes_.front().get();
    for (auto& lane : lanes_) {
        const size_t load = lane->markers.size() + (lane->waiting.serial ? 1 : 0);
        if (load < least->markers.size() + (least->waiting.serial ? 1 : 0)) least = lane.get();
    }
    return *least;
}

void CompletionFeed::watch(uint64_t boxedQueue, uint64_t serial) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closing_ || detached_) return;
        ++watches_;
        if (outstanding_ >= kMaxOutstanding) {
            ++unwatched_;
            records_.push_back({serial, kUnwatched});
            char one = 1;
            (void)!write(wake_[1], &one, 1);
            return;
        }
    }
    // The marker submission takes decoder locks: never under this feed's lock.
    Waiter wait = submit_(boxedQueue);
    if (!wait) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ++unwatched_;
        }
        push(serial, kUnwatched);
        return;
    }
    {
        std::unique_lock<std::mutex> lock(mutex_);
        if (closing_) {
            // The lanes may be gone: the marker is waited for here, releasing its device.
            lock.unlock();
            wait();
            return;
        }
        Lane& lane = laneForLocked(boxedQueue);
        lane.markers.push_back({serial, std::move(wait), boxedQueue, nowMs()});
        ++outstanding_;
        lane.changed.notify_one();
    }
}

void CompletionFeed::watcherLoop(Lane& lane) {
    for (;;) {
        Pending next;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            lane.changed.wait(lock, [&] { return closing_ || !lane.markers.empty(); });
            // Outstanding markers are always waited for: each holds its device alive.
            if (lane.markers.empty()) return;
            next = std::move(lane.markers.front());
            lane.markers.pop_front();
            lane.waiting = {next.serial, nullptr, next.queue, next.watchedMs};
        }
        const int32_t result = next.wait();
        next.wait = nullptr;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            lane.waiting = {};
            --outstanding_;
            lastCompletedSerial_ = next.serial;
            lastStatus_ = result == 0 ? kCompleted : kDeviceLost;
            lastCompletedMs_ = nowMs();
        }
        push(next.serial, result == 0 ? kCompleted : kDeviceLost);
    }
}

void CompletionFeed::push(uint64_t serial, int32_t status) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (detached_) return;
        records_.push_back({serial, status});
    }
    char one = 1;
    (void)!write(wake_[1], &one, 1);
}

int CompletionFeed::run(int fd, const std::atomic_bool& stop) {
    uint64_t mine;
    {
        // A later feed stream of the process (its connection was made again) takes over;
        // the earlier one returns at its next wake.
        std::lock_guard<std::mutex> lock(mutex_);
        mine = ++generation_;
        detached_ = false;
        attached_ = true;
    }
    for (int i = 0; i < 2; ++i) { char one = 1; (void)!write(wake_[1], &one, 1); }
    struct Detach {
        CompletionFeed* feed;
        uint64_t generation;
        ~Detach() {
            std::lock_guard<std::mutex> lock(feed->mutex_);
            if (feed->generation_ != generation) return;  // superseded: the new feed owns records
            // The guest is gone: records have no reader. The lanes keep waiting for
            // markers until close(), since each holds its device alive.
            feed->records_.clear();
            feed->detached_ = true;
            feed->attached_ = false;
        }
    } detach{this, mine};
    std::vector<unsigned char> out;
    for (;;) {
        std::deque<Record> ready;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (generation_ != mine) return 0;
            ready.swap(records_);
        }
        if (!ready.empty()) {
            out.assign(ready.size() * kRecordSize, 0);
            for (size_t i = 0; i < ready.size(); ++i) {
                std::memcpy(out.data() + i * kRecordSize, &ready[i].serial, 8);
                std::memcpy(out.data() + i * kRecordSize + 8, &ready[i].status, 4);
            }
            if (int error = sendAll(fd, out.data(), out.size())) return stop.load() ? 0 : error;
            std::lock_guard<std::mutex> lock(mutex_);
            lastWrittenSerial_ = ready.back().serial;
            lastWrittenMs_ = nowMs();
        }
        if (stop.load()) return 0;
        pollfd fds[2] = {{fd, POLLIN, 0}, {wake_[0], POLLIN, 0}};
        // A bounded wait, so a feed a later one took over notices and returns.
        if (poll(fds, 2, 100) < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            unsigned char byte;
            ssize_t got = recv(fd, &byte, 1, 0);
            if (got == 0 || stop.load()) return 0;  // guest EOF or process stop
            if (got > 0) return EPROTO;             // the feed accepts no further commands
            if (errno != EINTR && errno != EAGAIN) return errno;
        }
        if (fds[1].revents & POLLIN) {
            char drain[64];
            while (read(wake_[0], drain, sizeof(drain)) > 0) {}
        }
    }
}

}  // namespace caboose::gpuv2
