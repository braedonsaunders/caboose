// SPDX-License-Identifier: MIT
#include "flush_shadow.h"
#include <cassert>
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

    // Two separated edits send two block-aligned runs; the tail block ends at the range end.
    local[5000] ^= 1;
    local[size - 1] ^= 1;
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 2);
    assert(remote.sends[0] == std::make_pair(uint64_t(4864), uint64_t(256)));
    assert(remote.sends[1] == std::make_pair(uint64_t(64 * 1024), uint64_t(100)));
    assert(remote.bytes == local);

    // Adjacent changed blocks merge into one run, across a page boundary too.
    remote.sends.clear();
    local[8191] ^= 1; local[8192] ^= 1; local[8448] ^= 1; local[12288] ^= 1;
    assert(shadow.emitChanged(1, local.data(), size, 0, size, remote.sender(local)) == success);
    assert(remote.sends.size() == 2);
    assert(remote.sends[0] == std::make_pair(uint64_t(7936), uint64_t(768)));
    assert(remote.sends[1] == std::make_pair(uint64_t(12288), uint64_t(256)));
    assert(remote.bytes == local);

    // A partial page is sent within the chunk bounds and never trusted later.
    remote.sends.clear();
    std::vector<uint8_t> other(size, 7);
    Remote fresh{size};
    assert(shadow.emitChanged(2, other.data(), size, 100, 200, fresh.sender(other)) == success);
    assert(fresh.sends.size() == 1 && fresh.sends[0] == std::make_pair(uint64_t(100), uint64_t(200)));
    fresh.sends.clear();
    assert(shadow.emitChanged(2, other.data(), size, 0, 4096, fresh.sender(other)) == success);
    assert(fresh.sends.size() == 1 && fresh.sends[0] == std::make_pair(uint64_t(0), uint64_t(4096)));

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
    return 0;
}
