// SPDX-License-Identifier: MIT
// Exit 0 pass, 1 failure, 77 when userfaultfd write protection is unavailable.
#include "write_tracker.h"

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <random>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

using caboose::coherent::TrackedRegion;
using caboose::coherent::WriteTracker;
using caboose::coherent::trackerPageBytes;

namespace {
int failures = 0;
#define CHECK(condition)                                                              \
    do {                                                                              \
        if (!(condition)) {                                                           \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #condition); \
            ++failures;                                                               \
        }                                                                             \
    } while (0)

using Runs = std::vector<std::pair<uint64_t, uint64_t>>;

Runs consumeAll(TrackedRegion& region, uint64_t offset, uint64_t size) {
    Runs runs;
    const int result = region.consume(offset, size, [&](uint64_t o, uint64_t s) {
        runs.emplace_back(o, s);
        return 0;
    });
    CHECK(result == 0);
    return runs;
}

void basics(WriteTracker& tracker) {
    const uint64_t bytes = 64 * trackerPageBytes + 100;  // Unaligned logical size.
    auto region = tracker.allocate(bytes);
    CHECK(region);
    if (!region) return;
    CHECK(region->size() == bytes);
    CHECK(!region->written());
    CHECK(consumeAll(*region, 0, bytes).empty());

    // Reading never marks; a later store to the same page still faults.
    volatile uint8_t sink = region->data()[3 * trackerPageBytes];
    (void)sink;
    CHECK(!region->written());
    region->data()[3 * trackerPageBytes + 7] = 0x5a;
    CHECK(region->written());

    // The first fault releases its whole 16-page chunk.
    Runs runs = consumeAll(*region, 0, bytes);
    CHECK(runs.size() == 1 && runs[0].first == 0 && runs[0].second == 16 * trackerPageBytes);
    CHECK(!region->written());
    CHECK(consumeAll(*region, 0, bytes).empty());

    // Protection was re-armed: the next store faults again.
    region->data()[5 * trackerPageBytes] = 1;
    runs = consumeAll(*region, 0, bytes);
    CHECK(runs.size() == 1 && runs[0].first == 0);

    // The tail page past the logical size is clipped to the logical size.
    region->data()[bytes - 1] = 2;
    runs = consumeAll(*region, 0, bytes);
    CHECK(runs.size() == 1 && runs[0].first + runs[0].second == bytes);

    // A partial interval reports only its part and keeps a partly covered page marked.
    region->data()[20 * trackerPageBytes] = 3;
    runs = consumeAll(*region, 20 * trackerPageBytes + 64, 128);
    CHECK(runs.size() == 1 && runs[0].first == 20 * trackerPageBytes + 64 && runs[0].second == 128);
    CHECK(region->written());
    runs = consumeAll(*region, 16 * trackerPageBytes, 16 * trackerPageBytes);
    CHECK(runs.size() == 1 && runs[0].first == 16 * trackerPageBytes &&
          runs[0].second == 16 * trackerPageBytes);
    CHECK(!region->written());

    // A visitor's failure is returned.
    region->data()[0] = 4;
    CHECK(region->consume(0, bytes, [](uint64_t, uint64_t) { return -4; }) == -4);
}

// Kernel-origin stores (read(2) into the mapping) are tracked, not EFAULT.
void kernelStores(WriteTracker& tracker) {
    auto region = tracker.allocate(32 * trackerPageBytes);
    CHECK(region);
    if (!region) return;
    int fds[2];
    CHECK(pipe(fds) == 0);
    const char message[] = "kernel-origin store";
    CHECK(write(fds[1], message, sizeof(message)) == ssize_t(sizeof(message)));
    const ssize_t n = read(fds[0], region->data() + 17 * trackerPageBytes, sizeof(message));
    CHECK(n == ssize_t(sizeof(message)));
    CHECK(std::memcmp(region->data() + 17 * trackerPageBytes, message, sizeof(message)) == 0);
    close(fds[0]);
    close(fds[1]);
    Runs runs = consumeAll(*region, 0, region->size());
    CHECK(runs.size() == 1 && runs[0].first == 16 * trackerPageBytes);
}

// The transport reads mapped memory while the application stores to it; relaxed
// byte accesses model that without a formal data race.
void copyRacing(uint8_t* destination, const uint8_t* source, uint64_t size) {
    for (uint64_t i = 0; i < size; ++i) destination[i] = __atomic_load_n(source + i, __ATOMIC_RELAXED);
}

// A mirror updated only from consumed runs must converge to the region exactly
// while writers store concurrently with consumption.
void concurrentMirror(WriteTracker& tracker) {
    const uint64_t bytes = 4 << 20;
    auto region = tracker.allocate(bytes);
    CHECK(region);
    if (!region) return;
    std::vector<uint8_t> mirror(bytes, 0);
    std::atomic<bool> stop{false};
    std::vector<std::thread> writers;
    for (unsigned w = 0; w < 3; ++w) {
        writers.emplace_back([&, w] {
            std::mt19937_64 random(w + 1);
            uint8_t value = 1;
            while (!stop.load(std::memory_order_relaxed)) {
                const uint64_t offset = random() % bytes;
                // Each writer owns offsets congruent to w modulo 3.
                const uint64_t mine = offset - offset % 3 + w;
                if (mine < bytes) __atomic_store_n(region->data() + mine, value++, __ATOMIC_RELAXED);
                if (!value) value = 1;
            }
        });
    }
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(800);
    uint64_t rounds = 0;
    while (std::chrono::steady_clock::now() < deadline || rounds < 20) {
        region->consume(0, bytes, [&](uint64_t o, uint64_t s) {
            copyRacing(mirror.data() + o, region->data() + o, s);
            return 0;
        });
        ++rounds;
    }
    stop = true;
    for (auto& writer : writers) writer.join();
    region->consume(0, bytes, [&](uint64_t o, uint64_t s) {
        std::memcpy(mirror.data() + o, region->data() + o, s);
        return 0;
    });
    CHECK(std::memcmp(mirror.data(), region->data(), bytes) == 0);
    CHECK(rounds >= 20);
}

// A forked child neither registers through the parent's descriptor nor faults.
void forkedChild(WriteTracker& tracker) {
    auto region = tracker.allocate(16 * trackerPageBytes);
    CHECK(region);
    if (!region) return;
    const pid_t child = fork();
    if (child == 0) {
        region->data()[0] = 9;  // Unregistered copy: an ordinary store.
        _exit(WriteTracker::get() == nullptr ? 0 : 3);
    }
    int status = 0;
    CHECK(waitpid(child, &status, 0) == child);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CHECK(!region->written());
}

// Prints the cost of the three access patterns that matter: first touch of a
// fresh allocation, a frame that rewrites 1 MiB in place, and a frame of sparse
// small stores. These are measurements, not pass/fail thresholds.
void benchmark(WriteTracker& tracker) {
    const uint64_t bytes = 64 << 20;
    auto region = tracker.allocate(bytes);
    CHECK(region);
    if (!region) return;
    using Clock = std::chrono::steady_clock;
    const auto us = [](Clock::time_point a, Clock::time_point b) {
        return (unsigned long long)std::chrono::duration_cast<std::chrono::microseconds>(b - a).count();
    };
    const auto frame = [&](const char* name, auto store, uint64_t expectAtLeast) {
        const auto before = tracker.stats();
        const auto t0 = Clock::now();
        store();
        const auto t1 = Clock::now();
        uint64_t reported = 0;
        region->consume(0, bytes, [&](uint64_t, uint64_t s) { reported += s; return 0; });
        const auto t2 = Clock::now();
        const auto after = tracker.stats();
        const unsigned long long faults = after.faults - before.faults;
        std::printf("benchmark %-18s stores %6lluus faults %4llu (handler mean %6lluns) consume %4lluus reported %6lluKiB\n",
                    name, us(t0, t1), faults,
                    faults ? (unsigned long long)((after.faultNanos - before.faultNanos) / faults) : 0ULL,
                    us(t1, t2), (unsigned long long)(reported >> 10));
        CHECK(reported >= expectAtLeast);
    };
    frame("first-touch-64MiB", [&] {
        for (uint64_t o = 0; o < bytes; o += trackerPageBytes) region->data()[o] = 1;
    }, bytes);
    frame("rewrite-1MiB", [&] {
        for (uint64_t o = 0; o < (1 << 20); o += 64) region->data()[o] = 2;
    }, 1 << 20);
    frame("sparse-64x256B", [&] {
        for (uint64_t i = 0; i < 64; ++i) std::memset(region->data() + i * (1 << 20) + 4096, 3, 256);
    }, 64 * 256);
}

// A bounded extent never releases (or reports) more than its bound per fault.
void boundedExtent(WriteTracker& tracker) {
    const uint64_t bytes = 8 << 20;
    auto region = tracker.allocate(bytes, caboose::coherent::trackerChunkPages);
    CHECK(region);
    if (!region) return;
    for (uint64_t o = 0; o < (1 << 20); o += trackerPageBytes) region->data()[o] = 1;
    uint64_t reported = 0;
    region->consume(0, bytes, [&](uint64_t, uint64_t s) { reported += s; return 0; });
    CHECK(reported == (1 << 20));
}
}  // namespace

int main() {
    WriteTracker* tracker = WriteTracker::get();
    if (!tracker) {
        std::printf("write tracking unavailable: %s\n", std::strerror(WriteTracker::unavailableReason()));
        return 77;
    }
    std::printf("write tracking: unpopulated protection %s\n", tracker->unpopulatedProtection() ? "yes" : "no");
    basics(*tracker);
    kernelStores(*tracker);
    concurrentMirror(*tracker);
    forkedChild(*tracker);
    boundedExtent(*tracker);
    benchmark(*tracker);
    CHECK(tracker->stats().regions == 0);
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("write_tracker_test: pass");
    return 0;
}
