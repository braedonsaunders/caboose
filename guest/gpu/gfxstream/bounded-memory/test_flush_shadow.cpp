// SPDX-License-Identifier: MIT
#include "flush_shadow.h"
#include <algorithm>
#include <cassert>
#include <string>
#include <utility>
#include <vector>
using namespace caboose::memory;

namespace {
struct Remote {
    std::vector<uint8_t> bytes;
    std::vector<std::pair<uint64_t, uint64_t>> sends;
    int fail = success;
    explicit Remote(size_t size) : bytes(size, 0xEE) {}
    auto sender(const std::vector<uint8_t>& local) {
        return [this, &local](uint64_t offset, uint64_t size) {
            if (fail != success) return fail;
            std::memcpy(bytes.data() + offset, local.data() + offset, size_t(size));
            sends.emplace_back(offset, size);
            return success;
        };
    }
};
} // namespace

int main() {
    constexpr size_t size = 64 * 1024 + 100;
    Budget budget{64 * 1024 * 1024};
    FlushShadow shadow{budget};
    std::vector<uint8_t> local(size);
    for (size_t i = 0; i < size; ++i) local[i] = uint8_t(i * 31);
    Remote remote{size};

    // The first flush sends everything, as one run.
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 1 && remote.sends[0] == std::make_pair(uint64_t(0), uint64_t(size)));
    assert(remote.bytes == local);

    // Unchanged memory sends nothing.
    remote.sends.clear();
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.empty());

    // Of known blocks, the changed 8-byte words are sent; the tail word ends at the range end.
    local[5000] ^= 1;
    local[size - 1] ^= 1;
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 2);
    assert(remote.sends[0] == std::make_pair(uint64_t(5000), uint64_t(8)));
    assert(remote.sends[1] == std::make_pair(uint64_t(size - 4), uint64_t(4)));
    assert(remote.bytes == local);

    // Changed words of neighbouring blocks go as one run, across a page boundary too; words
    // further apart than a fragment's overhead go apart.
    remote.sends.clear();
    local[8191] ^= 1; local[8192] ^= 1; local[8448] ^= 1; local[8480] ^= 1; local[12288] ^= 1;
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 3);
    assert(remote.sends[0] == std::make_pair(uint64_t(8184), uint64_t(16)));
    assert(remote.sends[1] == std::make_pair(uint64_t(8448), uint64_t(40)));  // 8448 and 8480, 24 bytes apart
    assert(remote.sends[2] == std::make_pair(uint64_t(12288), uint64_t(8)));
    assert(remote.bytes == local);

    // A partial block is sent within the chunk bounds and never trusted later.
    remote.sends.clear();
    std::vector<uint8_t> other(size, 7);
    Remote fresh{size};
    assert(shadow.emitChanged(2, other.data(), size, 100, 100, fresh.sender(other)) == success);
    assert(fresh.sends.size() == 1 && fresh.sends[0] == std::make_pair(uint64_t(100), uint64_t(100)));
    fresh.sends.clear();
    assert(shadow.emitChanged(2, other.data(), size, 0, 256, fresh.sender(other)) == success);
    assert(fresh.sends.size() == 1 && fresh.sends[0] == std::make_pair(uint64_t(0), uint64_t(256)));

    // Whole blocks are trusted though their page was never sent whole: small ranges of a
    // large allocation, flushed again unchanged, send nothing.
    fresh.sends.clear();
    assert(shadow.emitChanged(2, other.data(), size, 8192 + 512, 1024, fresh.sender(other)) == success);
    assert(fresh.sends.size() == 1 && fresh.sends[0] == std::make_pair(uint64_t(8192 + 512), uint64_t(1024)));
    fresh.sends.clear();
    assert(shadow.emitChanged(2, other.data(), size, 8192 + 512, 1024, fresh.sender(other)) == success);
    assert(fresh.sends.empty());
    other[8192 + 700] ^= 1;
    assert(shadow.emitChanged(2, other.data(), size, 8192, 4096, fresh.sender(other)) == success);
    assert(fresh.sends.size() == 3);
    assert(fresh.sends[0] == std::make_pair(uint64_t(8192), uint64_t(512)));  // unknown blocks, whole
    assert(fresh.sends[1] == std::make_pair(uint64_t(8192 + 696), uint64_t(8)));  // the edit's word
    assert(fresh.sends[2] == std::make_pair(uint64_t(8192 + 1536), uint64_t(4096 - 1536)));
    assert(std::equal(other.begin() + 8192, other.begin() + 8192 + 4096, fresh.bytes.begin() + 8192));
    fresh.sends.clear();
    assert(shadow.emitChanged(2, other.data(), size, 8192, 4096, fresh.sender(other)) == success);
    assert(fresh.sends.empty());

    // An invalidate's refreshed bytes are known in whole blocks only.
    fresh.sends.clear();
    other[20000] = 1;
    shadow.noteRefreshed(2, other.data(), size, 19968, 300);
    assert(shadow.emitChanged(2, other.data(), size, 19968, 512, fresh.sender(other)) == success);
    assert(fresh.sends.size() == 1 && fresh.sends[0] == std::make_pair(uint64_t(19968 + 256), uint64_t(256)));

    // A range is unchanged only when every block it touches is held whole and its bytes match.
    remote.sends.clear();
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(shadow.unchanged(1, local.data(), size, 64, 4096) && shadow.unchanged(1, local.data(), size, 0, size));
    local[70] ^= 1;
    assert(!shadow.unchanged(1, local.data(), size, 64, 4096) && shadow.unchanged(1, local.data(), size, 4160, 4096));
    local[70] ^= 1;
    shadow.forgetRange(1, 5000, 5001);
    assert(!shadow.unchanged(1, local.data(), size, 4160, 4096) && shadow.unchanged(1, local.data(), size, 64, 4096));
    assert(!shadow.unchanged(9, local.data(), size, 0, 4096) && !shadow.unchanged(1, local.data(), size, size - 10, 4096));
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);

    // A device write forgets the blocks it touches, even partly, and only those.
    remote.sends.clear();
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.empty());
    shadow.forgetRange(1, 300, 520);
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 1 && remote.sends[0] == std::make_pair(uint64_t(256), uint64_t(512)));
    remote.sends.clear();
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.empty());
    shadow.forgetRange(1, 0, ~uint64_t(0));
    shadow.forgetRange(9, 0, size);
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 1 && remote.sends[0].second == size);

    // Forgetting resends in full; a failed send forgets too.
    remote.sends.clear();
    shadow.forget(1);
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 1 && remote.sends[0].second == size);
    local[0] ^= 1;
    remote.fail = -4;
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == -4);
    remote.fail = success; remote.sends.clear();
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 1 && remote.sends[0].second == size);

    // Allocations beyond the per-allocation cap or the budget are sent in full every time.
    Budget tiny{1024};
    FlushShadow capped{tiny};
    Remote full{size};
    for (int i = 0; i < 2; ++i)
        assert(capped.emitChanged(3, local.data(), size, 0, size, full.sender(local)) == success);
    assert(full.sends.size() == 2 && tiny.used() == 0);

    shadow.forget(1); shadow.forget(2);
    assert(budget.used() == 0);

    // An allocation no copy fits is known by block hashes: unchanged whole blocks are not
    // sent again, a changed one is, and a partly sent block is sent until it is sent whole.
    Budget small{8 * 1024};
    FlushShadow hashed{small};
    std::vector<uint8_t> big(size);
    for (size_t i = 0; i < size; ++i) big[i] = uint8_t(i * 7 + 3);
    Remote far{size};
    traffic::counters().take(0);  // opens the counters' window
    assert(hashed.emitChanged(4, big.data(), size, 0, size, far.sender(big)) == success);
    assert(far.sends.size() == 1 && far.sends[0].second == size && far.bytes == big);
    assert(small.used() > 0 && small.used() < size);
    far.sends.clear();
    assert(hashed.emitChanged(4, big.data(), size, 0, size, far.sender(big)) == success);
    assert(far.sends.empty());
    big[5000] ^= 1;
    big[size - 1] ^= 1;
    assert(hashed.emitChanged(4, big.data(), size, 0, size, far.sender(big)) == success);
    assert(far.sends.size() == 2);
    assert(far.sends[0] == std::make_pair(uint64_t(4864), uint64_t(256)));
    assert(far.sends[1] == std::make_pair(uint64_t(64 * 1024), uint64_t(100)));
    assert(far.bytes == big);
    far.sends.clear();
    big[300] ^= 1;
    assert(hashed.emitChanged(4, big.data(), size, 260, 100, far.sender(big)) == success);
    assert(far.sends.size() == 1 && far.sends[0] == std::make_pair(uint64_t(260), uint64_t(100)));
    far.sends.clear();
    assert(hashed.emitChanged(4, big.data(), size, 0, 1024, far.sender(big)) == success);
    assert(far.sends.size() == 1 && far.sends[0] == std::make_pair(uint64_t(256), uint64_t(256)));
    far.sends.clear();
    assert(hashed.emitChanged(4, big.data(), size, 0, 1024, far.sender(big)) == success);
    assert(far.sends.empty() && far.bytes == big);
    // unchanged() holds for whole known blocks whose hash matches, and not for part of one.
    assert(hashed.unchanged(4, big.data(), size, 0, 4096));
    assert(!hashed.unchanged(4, big.data(), size, 64, 4096));
    big[1000] ^= 1;
    assert(!hashed.unchanged(4, big.data(), size, 0, 4096));
    big[1000] ^= 1;
    // A device write forgets its blocks; an invalidate's whole blocks are known again.
    hashed.forgetRange(4, 512, 513);
    assert(!hashed.unchanged(4, big.data(), size, 0, 4096));
    hashed.noteRefreshed(4, big.data(), size, 512, 256);
    assert(hashed.unchanged(4, big.data(), size, 0, 4096));
    const std::string line = traffic::counters().take(5000);
    assert(line.find(" hashed_considered_bytes=") != std::string::npos);
    assert(line.find(" hashed_considered_bytes=0 ") == std::string::npos);
    // A range over part of a hashed block counts as partial.
    assert(line.find(" hashed_partial_bytes=0") == std::string::npos);
    hashed.forget(4);
    assert(small.used() == 0);
    // The traffic counters count what went and what whole changed blocks would have sent, in
    // all and per allocation.
    {
        FlushShadow measured{budget};
        std::vector<uint8_t> small(1024, 7);
        Remote near{small.size()};
        assert(measured.emitChanged(9, small.data(), small.size(), 0, small.size(), near.sender(small)) == success);
        traffic::counters().take(10000);
        small[10] ^= 1; small[200] ^= 1;   // block 0: words 8 and 200, 184 bytes apart
        small[300] ^= 1; small[330] ^= 1;  // block 1: words 296 and 328, 24 bytes apart
        near.sends.clear();
        assert(measured.emitChanged(9, small.data(), small.size(), 0, small.size(), near.sender(small), 0x10) == success);
        assert(near.sends.size() == 3);
        assert(near.sends[0] == std::make_pair(uint64_t(8), uint64_t(8)));
        assert(near.sends[1] == std::make_pair(uint64_t(200), uint64_t(8)));
        assert(near.sends[2] == std::make_pair(uint64_t(296), uint64_t(40)));
        assert(near.bytes == small);
        const std::string counted = traffic::counters().take(15000);
        assert(counted.find(" copied_considered_bytes=1024 copied_sent_bytes=56 ") != std::string::npos);
        assert(counted.find(" copied_runs=3 ") != std::string::npos);
        assert(counted.find(" block_bytes=512 block_runs=1 ") != std::string::npos);
        assert(counted.find("\nCABOOSE_GPU_MEMORY_ALLOCATION rank=1 shadow=copied bytes=1024 usage=0x10 "
                            "considered_bytes=1024 sent_bytes=56 runs=3 block_bytes=512 block_runs=1") != std::string::npos);
        measured.forget(9);
    }
    // XXH64 of the empty input and of "abc", as published.
    assert(blockHash(nullptr, 0) == 0xEF46DB3751D8E999ull);
    assert(blockHash(reinterpret_cast<const uint8_t*>("abc"), 3) == 0x44BC2CF5AD770999ull);
    return 0;
}
