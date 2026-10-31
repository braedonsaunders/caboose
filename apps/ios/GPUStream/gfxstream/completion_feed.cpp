// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "completion_feed.h"
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

CompletionFeed::CompletionFeed(Submit submit) : submit_(std::move(submit)) {
    if (pipe(wake_) != 0) throw std::system_error(errno, std::generic_category(), "completion feed pipe");
    for (int fd : wake_) {
        fcntl(fd, F_SETFD, FD_CLOEXEC);
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    }
    watcher_ = std::thread([this] { watcherLoop(); });
}

CompletionFeed::~CompletionFeed() {
    close();
    for (int fd : wake_) if (fd >= 0) ::close(fd);
}

void CompletionFeed::close() {
    cancelOrders();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        closing_ = true;
    }
    markersChanged_.notify_all();
    if (watcher_.joinable() && watcher_.get_id() != std::this_thread::get_id()) watcher_.join();
}

void CompletionFeed::watch(uint64_t boxedQueue, uint64_t serial) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (closing_ || detached_) return;
        if (markers_.size() >= kMaxOutstanding) {
            records_.push_back({serial, kUnwatched});
            char one = 1;
            (void)!write(wake_[1], &one, 1);
            return;
        }
    }
    // The marker submission takes decoder locks: never under this feed's lock.
    Waiter wait = submit_(boxedQueue);
    if (!wait) {
        push(serial, kUnwatched);
        return;
    }
    {
        std::unique_lock<std::mutex> lock(mutex_);
        if (closing_) {
            // The watcher may be gone: the marker is waited for here, releasing its device.
            lock.unlock();
            wait();
            return;
        }
        markers_.push_back({serial, std::move(wait)});
    }
    markersChanged_.notify_one();
}

void CompletionFeed::watcherLoop() {
    for (;;) {
        Pending next;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            markersChanged_.wait(lock, [this] { return closing_ || !markers_.empty(); });
            // Outstanding markers are always waited for: each holds its device alive.
            if (markers_.empty()) return;
            next = std::move(markers_.front());
            markers_.pop_front();
        }
        const int32_t result = next.wait();
        next.wait = nullptr;
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
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (attached_) return EBUSY;
        attached_ = true;
    }
    struct Detach {
        CompletionFeed* feed;
        ~Detach() {
            std::lock_guard<std::mutex> lock(feed->mutex_);
            // The guest is gone: records have no reader. The watcher keeps waiting for
            // markers until close(), since each holds its device alive.
            feed->records_.clear();
            feed->detached_ = true;
        }
    } detach{this};
    std::vector<unsigned char> out;
    for (;;) {
        std::deque<Record> ready;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ready.swap(records_);
        }
        if (!ready.empty()) {
            out.assign(ready.size() * kRecordSize, 0);
            for (size_t i = 0; i < ready.size(); ++i) {
                std::memcpy(out.data() + i * kRecordSize, &ready[i].serial, 8);
                std::memcpy(out.data() + i * kRecordSize + 8, &ready[i].status, 4);
            }
            if (int error = sendAll(fd, out.data(), out.size())) return stop.load() ? 0 : error;
        }
        if (stop.load()) return 0;
        pollfd fds[2] = {{fd, POLLIN, 0}, {wake_[0], POLLIN, 0}};
        if (poll(fds, 2, -1) < 0) {
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
