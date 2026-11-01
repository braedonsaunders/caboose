// SPDX-License-Identifier: MIT
// Written-block bookkeeping everywhere; the userfaultfd watch itself where the process may
// use userfaultfd (otherwise that part reports it skipped, as the driver then sends whole
// mappings).
#include "write_watch.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <thread>
#include <utility>
#include <vector>

using namespace caboose::memory;

namespace {

std::vector<std::pair<uint64_t, uint64_t>> runs(WrittenBlocks& blocks, uint64_t from, uint64_t to) {
    std::vector<std::pair<uint64_t, uint64_t>> out;
    blocks.take(from, to, [&](uint64_t begin, uint64_t end) { out.emplace_back(begin, end); });
    return out;
}

}  // namespace

int main() {
    constexpr uint64_t B = watchBlockBytes;
    {
        WrittenBlocks blocks(10 * B + 100);
        assert(!blocks.any() && runs(blocks, 0, 11 * B).empty());
        blocks.mark(5);
        blocks.mark(B + 1);       // joins the first block's run
        blocks.mark(4 * B);
        blocks.mark(10 * B + 50);  // the short last block
        blocks.mark(11 * B);       // beyond the allocation: ignored
        assert(blocks.any());
        // Runs are clipped to the range asked for and to the allocation, and taken once.
        assert((runs(blocks, 100, 11 * B) ==
                std::vector<std::pair<uint64_t, uint64_t>>{{100, 2 * B}, {4 * B, 5 * B}, {10 * B, 10 * B + 100}}));
        assert(!blocks.any() && runs(blocks, 0, 11 * B).empty());
        // Blocks outside the range asked for stay written.
        blocks.mark(0);
        blocks.mark(8 * B);
        assert((runs(blocks, 7 * B, 9 * B) == std::vector<std::pair<uint64_t, uint64_t>>{{8 * B, 9 * B}}));
        assert(blocks.any());
        assert((runs(blocks, 0, B / 2) == std::vector<std::pair<uint64_t, uint64_t>>{{0, B / 2}}));
        assert(!blocks.any());
    }

    WriteWatch& watch = writeWatch();
    if (!watch.available()) {
        std::puts("SKIP userfaultfd write watch: not available to this process");
        return 0;
    }
    const uint64_t bytes = 64 * B;
    auto* memory = static_cast<uint8_t*>(mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
    assert(memory != MAP_FAILED);
    assert(watch.watch(memory, bytes) && watch.watched(memory));
    assert(!watch.watch(memory + 1, B));  // not page-aligned
    auto written = [&](uint64_t from, uint64_t to) {
        std::vector<std::pair<uint64_t, uint64_t>> out;
        assert(watch.written(memory, from, to, [&](uint64_t begin, uint64_t end) { out.emplace_back(begin, end); }));
        return out;
    };
    // Nothing counts as written until it is written, including memory never touched.
    assert(written(0, bytes).empty());
    memory[3 * B + 10] = 1;                 // one block
    std::memset(memory + 10 * B, 7, 3 * B);  // three blocks, one run
    std::thread([&] { memory[40 * B] = 2; }).join();  // another thread's write
    const uint64_t faults = watch.faults();
    memory[3 * B + 20] = 3;  // the block is already unprotected: no fault
    assert(watch.faults() == faults);
    assert((written(0, bytes) ==
            std::vector<std::pair<uint64_t, uint64_t>>{{3 * B, 4 * B}, {10 * B, 13 * B}, {40 * B, 41 * B}}));
    // Taken blocks are protected again: the next write is recorded anew.
    assert(written(0, bytes).empty());
    memory[3 * B] = 4;
    assert((written(0, bytes) == std::vector<std::pair<uint64_t, uint64_t>>{{3 * B, 4 * B}}));
    assert(memory[3 * B] == 4 && memory[3 * B + 20] == 3 && memory[11 * B] == 7);
    // The kernel's own writes (a read() into the memory) proceed and are recorded.
    {
        int pipe_fds[2];
        assert(pipe(pipe_fds) == 0);
        const char text[] = "written by the kernel";
        assert(write(pipe_fds[1], text, sizeof(text)) == ssize_t(sizeof(text)));
        assert(read(pipe_fds[0], memory + 20 * B + 5, sizeof(text)) == ssize_t(sizeof(text)));
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        assert(std::memcmp(memory + 20 * B + 5, text, sizeof(text)) == 0);
        assert((written(0, bytes) == std::vector<std::pair<uint64_t, uint64_t>>{{20 * B, 21 * B}}));
    }
    // Unwatched memory is reported as such, and writes to it are plain writes.
    watch.unwatch(memory);
    assert(!watch.watched(memory));
    assert(!watch.written(memory, 0, bytes, [](uint64_t, uint64_t) { assert(false); }));
    memory[5 * B] = 5;
    munmap(memory, bytes);
    std::puts("PASS write watch: written blocks, userfaultfd protection, re-protection and unwatching");
    return 0;
}
