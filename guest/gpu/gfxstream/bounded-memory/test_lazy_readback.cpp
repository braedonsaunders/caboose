// SPDX-License-Identifier: MIT
// Lazy readback (write_watch.h): lazy-block bookkeeping everywhere; fills on first use where
// the process may use userfaultfd (otherwise that part reports it skipped, as the driver then
// reads every invalidated range at once).
#include "write_watch.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <sys/mman.h>
#include <thread>
#include <vector>
using caboose::memory::LazyBlocks;
using caboose::memory::WriteWatch;
using caboose::memory::writeWatch;
using Runs = std::vector<std::pair<uint64_t, uint64_t>>;
static constexpr uint64_t B = caboose::memory::watchBlockBytes;

// The phone's copy of the test memory: byte i of allocation 7 holds (i / 4096 + 1) & 0xff.
static std::atomic<int> fetches{0};
static std::atomic<uint64_t> fetchedBytes{0};
static std::atomic<int> generation{1};
static bool fetch(uint64_t device, uint64_t memory, uint64_t offset, uint64_t size, uint8_t* out, bool) {
    assert(device == 3 && memory == 7);
    ++fetches;
    fetchedBytes += size;
    for (uint64_t i = 0; i < size; ++i) out[i] = uint8_t(((offset + i) / 4096 + generation) & 0xff);
    return true;
}

int main() {
    {
        LazyBlocks lazy(10 * B + 100);
        assert(lazy.blockCount() == 11 && lazy.count() == 0);
        lazy.set(2, true); lazy.set(3, true); lazy.set(4, true); lazy.set(7, true); lazy.set(3, true);
        assert(lazy.count() == 4 && lazy.lazy(3) && !lazy.lazy(5));
        assert(lazy.runFrom(2, 3) == 3 && lazy.runFrom(2, 2) == 2 && lazy.runFrom(5, 3) == 0 && lazy.runFrom(7, 3) == 1);
        Runs runs;
        lazy.runs(B + 5, 8 * B - 1, [&](uint64_t b, uint64_t e) { runs.emplace_back(b, e); });
        assert((runs == Runs{{2 * B, 5 * B}, {7 * B, 8 * B - 1}}));
        lazy.set(10, true);
        runs.clear();
        lazy.runs(0, UINT64_MAX, [&](uint64_t b, uint64_t e) { runs.emplace_back(b, e); });
        assert(runs.back() == std::make_pair(10 * B, 10 * B + 100));  // clipped to the allocation
        assert(lazy.generation(4) == 0);
        lazy.renew(4);
        assert(lazy.generation(4) == 1 && lazy.generation(3) == 0);
        lazy.set(3, false);
        assert(lazy.count() == 4 && !lazy.lazy(3));
    }

    WriteWatch& watch = writeWatch();
    if (!watch.available()) {
        std::puts("SKIP lazy readback fills: userfaultfd is not available to this process");
        return 0;
    }
    watch.setFetch(&fetch);
    const uint64_t bytes = 16 * B, allocation = 16 * B - 1000;
    auto* memory = static_cast<uint8_t*>(mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    assert(memory != MAP_FAILED);
    assert(watch.watch(memory, bytes));
    std::memset(memory, 0x55, 4 * B);  // the application's writes, sent by the next flush
    auto lazyOf = [&](uint64_t begin, uint64_t end, uint64_t mapBegin = 0, uint64_t mapEnd = 16 * B - 1000) {
        Runs runs;
        watch.makeLazy(memory, 3, 7, allocation, mapBegin, mapEnd, begin, end,
                       [&](uint64_t b, uint64_t e) { runs.emplace_back(b, e); });
        return runs;
    };
    // Blocks holding writes not yet sent are read at once: none of [0, 4B) is lazy.
    assert(lazyOf(0, 4 * B).empty());
    watch.written(memory, 0, bytes, [](uint64_t, uint64_t) {});  // the flush sent them
    // Whole blocks are lazy, rounded out from the range; the runs are clipped to it.
    assert((lazyOf(B + 100, 3 * B) == Runs{{B + 100, 3 * B}}));
    // Outside the mapping nothing is lazy.
    assert(lazyOf(5 * B, 6 * B, 0, 5 * B).empty());
    const auto before = watch.lazyStats();
    assert(before.made >= 2 * B);
    // Nothing touched: nothing read.
    assert(fetches == 0);
    // The first read of a lazy block fills it and the lazy block after it, in one fetch.
    assert(memory[B + 10] == uint8_t(B / 4096 + 1) && fetches == 1);
    assert(memory[2 * B + 4096] == uint8_t((2 * B + 4096) / 4096 + 1) && fetches == 1);
    // A block that was not lazy keeps its bytes.
    assert(memory[0] == 0x55);
    // A write after the fill is recorded, as any write is.
    memory[B + 1] = 9;
    Runs written;
    watch.written(memory, 0, bytes, [&](uint64_t b, uint64_t e) { written.emplace_back(b, e); });
    assert((written == Runs{{B, 2 * B}}));
    assert(memory[B + 1] == 9 && memory[B + 2] == uint8_t(B / 4096 + 1));
    // A write to a lazy block fills it first, then lands, and is recorded.
    assert((lazyOf(6 * B, 7 * B) == Runs{{6 * B, 7 * B}}));
    std::thread([&] { memory[6 * B + 3] = 0x77; }).join();
    assert(memory[6 * B + 3] == 0x77 && memory[6 * B + 4] == uint8_t(6 * B / 4096 + 1));
    written.clear();
    watch.written(memory, 0, bytes, [&](uint64_t b, uint64_t e) { written.emplace_back(b, e); });
    assert((written == Runs{{6 * B, 7 * B}}));
    // The kernel's accesses are filled too.
    assert((lazyOf(8 * B, 9 * B) == Runs{{8 * B, 9 * B}}));
    {
        int fds[2];
        assert(pipe(fds) == 0);
        assert(write(fds[1], memory + 8 * B, 16) == 16);
        uint8_t out[16];
        assert(read(fds[0], out, 16) == 16 && out[0] == uint8_t(8 * B / 4096 + 1));
        close(fds[0]); close(fds[1]);
    }
    // A completion record stores only what is not lazy; no block becomes lazy meanwhile.
    assert((lazyOf(10 * B, 11 * B) == Runs{{10 * B, 11 * B}}));
    Runs parts;
    watch.beginDelivery(memory, 9 * B, 3 * B, [&](uint64_t b, uint64_t e) { parts.emplace_back(b, e); });
    assert((parts == Runs{{9 * B, 10 * B}, {11 * B, 12 * B}}));
    assert(lazyOf(12 * B, 13 * B).empty());
    watch.endDelivery(memory);
    // A settle fills the lazy blocks of a range on the calling thread.
    const int fetchesBefore = fetches;
    watch.settle(memory, 10 * B, 11 * B, true);
    assert(fetches == fetchesBefore + 1);
    Runs left;
    watch.lazyRuns(memory, 0, bytes, [&](uint64_t b, uint64_t e) { left.emplace_back(b, e); });
    assert(left.empty());
    // The last block is filled up to the allocation's end and zero after it.
    assert((lazyOf(15 * B, 16 * B) == Runs{{15 * B, allocation}}));
    assert(memory[allocation - 1] == uint8_t((allocation - 1) / 4096 + 1) && memory[allocation + 10] == 0);
    // Memory never used in watched memory that had lazy blocks reads zero.
    assert(memory[13 * B + 5] == 0);
    // Newer writes to a block still lazy: a fill reads the newer bytes.
    generation = 2;
    assert((lazyOf(4 * B, 5 * B) == Runs{{4 * B, 5 * B}}));
    assert((lazyOf(4 * B, 5 * B) == Runs{{4 * B, 5 * B}}));
    assert(memory[4 * B] == uint8_t(4 * B / 4096 + 2));
    const auto after = watch.lazyStats();
    assert(after.fills > before.fills && after.filled > before.filled);
    watch.unwatch(memory);
    munmap(memory, bytes);
    std::printf("PASS lazy readback: lazy blocks, fills on first read, write and kernel access, deliveries, "
                "settles and allocation ends (%d fetches, %llu bytes)\n", fetches.load(),
                (unsigned long long)fetchedBytes.load());
    return 0;
}
