// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "executor_gate.h"
#include <cerrno>

namespace caboose::gpuv2 {
namespace { thread_local int idleDepth = 0; }

ExecutorGate& ExecutorGate::instance() {
    static ExecutorGate gate;
    return gate;
}

void ExecutorGate::enter() {
    std::lock_guard<std::mutex> lock(mutex_);
    ++threads_;
}

void ExecutorGate::leave() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        --threads_;
    }
    changed_.notify_all();
}

void ExecutorGate::idle(bool value) {
    // Nested idle scopes (a read inside an idle feed loop) count once.
    if (value ? idleDepth++ != 0 : --idleDepth != 0) return;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        value ? ++quiet_ : --quiet_;
    }
    changed_.notify_all();
}

bool ExecutorGate::pass(const std::atomic_bool& stop) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!closed_) return !stop.load();
    ++quiet_;
    changed_.notify_all();
    // Process stop sets `stop` without notifying this gate: look again now and then.
    while (closed_ && !stop.load()) changed_.wait_for(lock, std::chrono::milliseconds(20));
    --quiet_;
    return !stop.load();
}

int ExecutorGate::close(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    closed_ = true;
    return changed_.wait_for(lock, timeout, [this] { return quiet_ >= threads_; }) ? 0 : ETIMEDOUT;
}

void ExecutorGate::open() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        closed_ = false;
    }
    changed_.notify_all();
}

bool ExecutorGate::closed() {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
}

}  // namespace caboose::gpuv2
