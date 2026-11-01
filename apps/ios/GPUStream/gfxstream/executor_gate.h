// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <mutex>

namespace caboose::gpuv2 {

// The executor's suspension gate (docs/gpu-live.md, "Suspending an executor"). Every decoder
// thread registers for its life and passes the gate before each command. Closing the gate
// lets each command already running finish; the thread then parks before its next one.
// A thread waiting for input is idle as it is. Once every registered thread is idle or
// parked, no command runs, so no new GPU work starts, until the gate opens again.
class ExecutorGate {
public:
    static ExecutorGate& instance();

    // RAII registration of the calling decoder thread.
    class Thread {
    public:
        explicit Thread(ExecutorGate& gate) : gate_(gate) { gate_.enter(); }
        ~Thread() { gate_.leave(); }
        Thread(const Thread&) = delete;
        Thread& operator=(const Thread&) = delete;
    private:
        ExecutorGate& gate_;
    };
    // RAII: the calling registered thread waits for input, or does no GPU work at all.
    class Idle {
    public:
        explicit Idle(ExecutorGate& gate) : gate_(gate) { gate_.idle(true); }
        ~Idle() { gate_.idle(false); }
        Idle(const Idle&) = delete;
        Idle& operator=(const Idle&) = delete;
    private:
        ExecutorGate& gate_;
    };

    // Before a command: parks while the gate is closed. False once `stop` is set, which ends
    // the wait so a stopped process can retire.
    bool pass(const std::atomic_bool& stop);
    // Closes the gate and waits up to `timeout` until no command runs. 0, or ETIMEDOUT with
    // the gate still closed: the commands still running park when they finish.
    int close(std::chrono::milliseconds timeout);
    void open();
    bool closed();

private:
    void enter();
    void leave();
    void idle(bool value);
    std::mutex mutex_;
    std::condition_variable changed_;
    bool closed_ = false;
    size_t threads_ = 0;
    size_t quiet_ = 0;  // registered threads idle or parked
};

}  // namespace caboose::gpuv2
