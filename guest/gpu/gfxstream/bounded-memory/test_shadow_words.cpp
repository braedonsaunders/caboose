// SPDX-License-Identifier: MIT
// CABOOSE_SHADOW_WORDS=0: a changed known block goes whole, as before word-level sends.
#include "flush_shadow.h"
#include <cassert>
#include <cstdlib>
#include <utility>
#include <vector>
using namespace caboose::memory;

int main() {
    setenv("CABOOSE_SHADOW_WORDS", "0", 1);
    constexpr size_t size = 4096;
    Budget budget{64 * 1024 * 1024};
    FlushShadow shadow{budget};
    std::vector<uint8_t> local(size, 7), remote(size, 0);
    std::vector<std::pair<uint64_t, uint64_t>> sends;
    auto sender = [&](uint64_t offset, uint64_t length) {
        std::memcpy(remote.data() + offset, local.data() + offset, size_t(length));
        sends.emplace_back(offset, length);
        return int(success);
    };
    assert(shadow.emitChanged(1, local.data(), size, 0, size, sender) == success);
    sends.clear();
    local[300] ^= 1;  // one word of block 1
    assert(shadow.emitChanged(1, local.data(), size, 0, size, sender) == success);
    assert(sends.size() == 1 && sends[0] == std::make_pair(uint64_t(256), uint64_t(256)));
    assert(remote == local);
    return 0;
}
