// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Build: c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG -I apps/ios/GPUStream/gfxstream \
//   apps/ios/GPUStream/gfxstream/tests/executor_gate_test.cpp \
//   apps/ios/GPUStream/gfxstream/executor_gate.cpp -o /tmp/caboose-executor-gate-test
#include "executor_gate.h"
#include <cassert>
#include <cerrno>
#include <cstdio>
#include <thread>
using caboose::gpuv2::ExecutorGate;
using namespace std::chrono_literals;

namespace {
// A decoder thread: runs `commands` commands, each taking `work`, waiting `wait` for
// input between them.
struct Decoder {
    std::atomic_bool stop{false};
    std::atomic_int ran{0};
    std::thread thread;
    Decoder(ExecutorGate& gate, int commands, std::chrono::milliseconds work, std::chrono::milliseconds wait) {
        thread = std::thread([&gate, this, commands, work, wait] {
            ExecutorGate::Thread registered(gate);
            for (int i = 0; i < commands; ++i) {
                { ExecutorGate::Idle idle(gate); std::this_thread::sleep_for(wait); }
                if (!gate.pass(stop)) return;
                std::this_thread::sleep_for(work);
                ++ran;
            }
        });
    }
    ~Decoder() { stop = true; thread.join(); }
};
}

int main() {
    {
        // No decoder: closing succeeds at once and nothing parks.
        ExecutorGate gate;
        assert(gate.close(0ms) == 0 && gate.closed());
        gate.open();
        assert(!gate.closed());
    }
    {
        // A running command finishes before the close returns; no later one starts until open.
        ExecutorGate gate;
        Decoder busy(gate, 1000, 30ms, 0ms);
        while (busy.ran == 0) std::this_thread::sleep_for(1ms);
        assert(gate.close(2000ms) == 0);
        const int at = busy.ran;
        std::this_thread::sleep_for(100ms);
        assert(busy.ran == at);
        gate.open();
        while (busy.ran == at) std::this_thread::sleep_for(1ms);
    }
    {
        // A thread waiting for input does not hold the close back.
        ExecutorGate gate;
        Decoder waiting(gate, 1, 0ms, 500ms);
        std::this_thread::sleep_for(20ms);
        const auto start = std::chrono::steady_clock::now();
        assert(gate.close(2000ms) == 0);
        assert(std::chrono::steady_clock::now() - start < 200ms);
        gate.open();
    }
    {
        // A command longer than the timeout: ETIMEDOUT, the gate stays closed, and the
        // thread parks once its command ends.
        ExecutorGate gate;
        Decoder slow(gate, 2, 300ms, 0ms);
        std::this_thread::sleep_for(20ms);
        assert(gate.close(10ms) == ETIMEDOUT && gate.closed());
        assert(gate.close(2000ms) == 0 && slow.ran == 1);
        // A stopped process leaves the gate without running its command.
        slow.stop = true;
        slow.thread.join();
        assert(slow.ran == 1);
        slow.thread = std::thread([] {});
        gate.open();
    }
    std::puts("executor gate: ok");
    return 0;
}
