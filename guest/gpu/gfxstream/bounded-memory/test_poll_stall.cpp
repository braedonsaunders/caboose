// SPDX-License-Identifier: MIT
#include "poll_stall.h"

#include <cassert>
#include <string>
#include <vector>

using namespace caboose::memory;

int main() {
    uint64_t now = 0;
    std::vector<std::string> lines;
    PollStall stall([&] { return now; }, [&](const std::string& line) { lines.push_back(line); });
    unsigned described = 0;
    auto describe = [&] { ++described; return std::string("state=pending"); };

    // Not ready for under 10 s: nothing.
    for (; now < 9000; now += 1000) stall.poll("vkGetFenceStatus", 0x10, false, describe);
    assert(lines.empty() && described == 0);
    // At 10 s: one line, then quiet for a minute, then again.
    for (; now <= 12000; now += 1000) stall.poll("vkGetFenceStatus", 0x10, false, describe);
    assert(lines.size() == 1 && described == 1);
    assert(lines[0] == "CABOOSE_GPU_POLL_STALLED call=vkGetFenceStatus object=0x10 seconds=10 polls=11 state=pending");
    for (; now < 70000; now += 1000) stall.poll("vkGetFenceStatus", 0x10, false, describe);
    assert(lines.size() == 1);
    stall.poll("vkGetFenceStatus", 0x10, false, describe);
    assert(lines.size() == 2 && lines[1].find("seconds=70") != std::string::npos);
    // Ready starts it over; another object or call is separate.
    stall.poll("vkGetFenceStatus", 0x10, true, describe);
    now += 20000;
    stall.poll("vkGetFenceStatus", 0x10, false, describe);
    stall.poll("vkGetQueryPoolResults", 0x10, false, describe);
    assert(lines.size() == 2);

    // A value that keeps changing never stalls; one that stays the same does.
    lines.clear();
    for (uint64_t v = 0; v < 30; ++v, now += 1000) stall.value("vkGetSemaphoreCounterValue", 0x20, v, describe);
    assert(lines.empty());
    for (int i = 0; i < 12; ++i, now += 1000) stall.value("vkGetSemaphoreCounterValue", 0x20, 7, describe);
    assert(lines.size() == 1 && lines[0].find("call=vkGetSemaphoreCounterValue object=0x20") != std::string::npos);
    return 0;
}
