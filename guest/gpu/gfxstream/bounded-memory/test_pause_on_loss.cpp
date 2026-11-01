// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
//
// CABOOSE_GPU_ON_LOSS=pause against the broker's socket (completion_feed.h): a paused
// process holds a loss until a new executor's socket appears, also when its device stream
// ends before the broker removes the old socket and when the phone reports the loss in a
// reply before the streams end; a loss while the executor stays is reported after the grace.
#include "completion_feed.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

using namespace caboose::completion;
using Clock = std::chrono::steady_clock;

static std::string socketPath;
static int listener = -1;

static void bindSocket() {
    listener = socket(AF_UNIX, SOCK_STREAM, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::snprintf(address.sun_path, sizeof address.sun_path, "%s", socketPath.c_str());
    assert(bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof address) == 0);
}
static void removeSocket() {
    unlink(socketPath.c_str());
    close(listener);
    listener = -1;
}
static long since(Clock::time_point start) {
    return long(std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count());
}

int main() {
    char directory[] = "/tmp/caboose-pause-XXXXXX";
    assert(mkdtemp(directory));
    socketPath = std::string(directory) + "/gpu.sock";
    setenv("CABOOSE_GPU_ON_LOSS", "auto", 1);  // a game: neither Chromium nor Qt
    setenv("CABOOSE_GFXSTREAM_SOCKET", socketPath.c_str(), 1);
    assert(pauseOnLoss());
    departureGraceMs = 300;

    // Results other than device loss pass at once.
    bindSocket();
    auto start = Clock::now();
    assert(heldLoss(0) == 0 && heldLoss(-3) == -3);
    assert(since(start) < 100);

    // The phone reports device loss while its executor stays: reported after the grace.
    start = Clock::now();
    assert(heldLoss(-4) == -4);
    assert(since(start) >= 300 && !executorLost.load());

    // The phone reports the loss, then its executor leaves (socket removed, streams end)
    // and a new one comes: the loss is held until the new executor's socket is there.
    // Timed before the helper starts, which may run first under load.
    start = Clock::now();
    std::thread departure([] {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        removeSocket();
        markExecutorLost();
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        bindSocket();
    });
    assert(heldLoss(-4) == -4);
    assert(since(start) >= 500);
    departure.join();
    executorConnected();

    // The device stream ends before the broker removes the old socket.
    noteExecutorSocket();
    markExecutorLost();
    // Timed before the helper starts, which may run first under load.
    start = Clock::now();
    std::thread late([] {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        removeSocket();
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        bindSocket();
    });
    awaitExecutorReturn();
    assert(since(start) >= 500);
    late.join();
    executorConnected();

    // One stream fails while the executor and its socket stay: nothing returns, so the
    // loss is reported once the grace has passed.
    markExecutorLost();
    start = Clock::now();
    awaitExecutorReturn();
    const long waited = since(start);
    assert(waited >= 300 && waited < 1000);

    removeSocket();
    rmdir(directory);
    std::puts("pause on loss tests passed");
    return 0;
}
