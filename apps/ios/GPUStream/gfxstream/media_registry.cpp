// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "media_registry.h"

namespace caboose::gpuv2::media {
Registry& Registry::instance() {
    static Registry* registry = new Registry;  // outlives every decoder thread
    return *registry;
}

void Registry::open(const Token& token) {
    std::lock_guard<std::mutex> lock(mutex_);
    connections_[token];
}

void Registry::close(const Token& token) {
    std::map<uint32_t, Surface> dropped;  // pictures are released outside the lock
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = connections_.find(token);
        if (it == connections_.end()) return;
        dropped.swap(it->second);
        connections_.erase(it);
    }
    changed_.notify_all();
}

void Registry::forget(const Token& token, uint32_t surface) {
    std::shared_ptr<Picture> dropped;
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = connections_.find(token);
    if (it == connections_.end()) return;
    auto s = it->second.find(surface);
    if (s == it->second.end()) return;
    dropped = std::move(s->second.picture);
    // Keep the serials: a stale latch for a forgotten picture must not wait.
    s->second.failed = s->second.serial;
}

void Registry::publish(const Token& token, uint32_t surface, uint64_t serial,
                       std::shared_ptr<Picture> picture) {
    std::shared_ptr<Picture> replaced;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = connections_.find(token);
        if (it == connections_.end()) return;
        auto s = it->second.find(surface);
        if (s == it->second.end()) {
            if (it->second.size() >= kMaxSurfaces) return;
            s = it->second.emplace(surface, Surface{}).first;
        }
        if (serial < s->second.serial) return;
        replaced = std::move(s->second.picture);
        s->second.serial = serial;
        s->second.picture = std::move(picture);
    }
    changed_.notify_all();
}

void Registry::failed(const Token& token, uint32_t surface, uint64_t serial) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = connections_.find(token);
        if (it == connections_.end()) return;
        auto s = it->second.find(surface);
        if (s == it->second.end()) {
            if (it->second.size() >= kMaxSurfaces) return;
            s = it->second.emplace(surface, Surface{}).first;
        }
        if (serial > s->second.failed) s->second.failed = serial;
    }
    changed_.notify_all();
}

Registry::Wait Registry::waitFor(const Token& token, uint32_t surface, uint64_t serial,
                                 std::chrono::steady_clock::time_point deadline,
                                 std::shared_ptr<Picture>* out) {
    std::unique_lock<std::mutex> lock(mutex_);
    for (;;) {
        auto it = connections_.find(token);
        // HELLO precedes every surface the connection names, so an unknown token is gone.
        if (it == connections_.end()) return Wait::gone;
        auto s = it->second.find(surface);
        if (s != it->second.end()) {
            if (s->second.serial == serial && s->second.picture) {
                *out = s->second.picture;
                return Wait::ready;
            }
            if (s->second.serial > serial) return Wait::superseded;
            if (s->second.failed >= serial) return Wait::failed;
        }
        if (changed_.wait_until(lock, deadline) == std::cv_status::timeout) {
            // One last look: the change may have raced the deadline.
            auto again = connections_.find(token);
            if (again == connections_.end()) return Wait::gone;
            auto t = again->second.find(surface);
            if (t != again->second.end() && t->second.serial == serial && t->second.picture) {
                *out = t->second.picture;
                return Wait::ready;
            }
            return Wait::timeout;
        }
    }
}
}
