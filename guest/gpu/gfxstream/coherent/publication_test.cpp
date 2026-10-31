// SPDX-License-Identifier: AGPL-3.0-or-later
#include "publication.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <thread>
using namespace caboose::coherent;
#define REQUIRE(x) do { if (!(x)) { std::fprintf(stderr, "line %d: %s\n", __LINE__, #x); std::abort(); } } while (0)
int main() {
    std::array<uint8_t, 4096> memory{};
    Publisher p;
    REQUIRE(p.attach(1, memory.data(), memory.size()));
    // Ordinary concurrent host stores in the SAME page and word as GPU bytes.
    // No test-only accessor mediates the host's stores.
    std::thread host([&] { for (unsigned i=0;i<100000;++i) memory[0]=uint8_t(i); });
    REQUIRE(p.publish({{1,1},{},{{1,1,{7}}}}) == Result::published);
    host.join();
    REQUIRE(memory[0]==uint8_t(99999) && memory[1]==7 && memory[2]==0);
    // Independent queues can publish out of order, including allocation aliases.
    REQUIRE(p.publish({{2,1},{},{{1,4,{9}}}}) == Result::published);
    REQUIRE(p.publish({{1,3},{},{{1,5,{11}}}}) == Result::pending);
    REQUIRE(memory[5]==0);
    REQUIRE(p.publish({{3,1},{{1,2}},{{1,4,{12}}}}) == Result::pending);
    REQUIRE(p.publish({{1,2},{},{{1,4,{10}}}}) == Result::published);
    REQUIRE(p.publish({{3,1},{{1,2}},{{1,4,{12}}}}) == Result::published);
    REQUIRE(memory[4]==12);
    REQUIRE(p.publish({{1,3},{},{{1,5,{11}}}}) == Result::published);
    // A same-value device store still owns its byte: do not discard it by diff.
    memory[6]=42;
    REQUIRE(p.publish({{1,4},{},{{1,6,{0}}}}) == Result::published);
    REQUIRE(memory[6]==0);
    // Malformed tail must not partially publish a valid prefix.
    REQUIRE(p.publish({{1,5},{},{{1,7,{13}},{1,4096,{1}}}}) == Result::lost);
    REQUIRE(memory[7]==0);
    REQUIRE(p.publish({{1,5},{},{{1,7,{13}}}}) == Result::lost);
    // Loss is local to this logical device.
    Publisher second;
    REQUIRE(second.attach(1,memory.data(),memory.size()));
    REQUIRE(second.publish({{1,1},{},{{1,7,{14}}}}) == Result::published);
    memory[7]=15;
    REQUIRE(second.publish({{1,1},{},{{1,7,{14}}}}) == Result::lost);
    REQUIRE(memory[7]==15); // replay cannot overwrite a later CPU store
    Publisher recycled;
    REQUIRE(recycled.attach(1,memory.data(),memory.size()));
    recycled.detach(1);
    REQUIRE(!recycled.attach(1,memory.data(),memory.size()));
    REQUIRE(recycled.attach(2,memory.data(),memory.size()));
    REQUIRE(recycled.publish({{1,1},{},{{1,0,{9}}}}) == Result::lost);
    Publisher overlap;
    REQUIRE(overlap.attach(1,memory.data(),memory.size()));
    REQUIRE(overlap.publish({{1,1},{},{{1,20,{1,2}},{1,21,{3}}}}) == Result::lost);
    REQUIRE(memory[20]==0 && memory[21]==0);
    std::puts("publication core: PASS (not a Vulkan coherence proof)");
}
