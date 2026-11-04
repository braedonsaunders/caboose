// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// The phone's completion payloads against the guest's own encoder and parser
// (guest/gpu/gfxstream/bounded-memory/completion_payloads.h): a guest WATCH2 parses on the
// phone, and the record the phone writes for it parses in the guest to the captured data.
// Build: c++ -std=c++17 -Wall -Wextra -Werror -pthread -UNDEBUG -I apps/ios/GPUStream/gfxstream \
//   -I guest/gpu/gfxstream/bounded-memory apps/ios/GPUStream/gfxstream/tests/completion_payloads_cross_test.cpp \
//   apps/ios/GPUStream/gfxstream/completion_feed.cpp -o /tmp/caboose-completion-payloads-cross-test
#include "completion_feed.h"
#include "completion_payloads.h"

#include <atomic>
#include <cassert>
#include <cstring>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

using caboose::gpuv2::CompletionFeed;
namespace guest = caboose::completion::payloads;

static void readExactly(int fd, uint8_t* out, size_t size) {
    for (size_t got = 0; got < size;) {
        const ssize_t n = read(fd, out + got, size - got);
        assert(n > 0);
        got += size_t(n);
    }
}

int main() {
    static_assert(guest::kWatch2Opcode == CompletionFeed::kWatch2Opcode);
    static_assert(guest::kWatch2HeaderSize == CompletionFeed::kWatch2HeaderSize);
    static_assert(guest::kEntrySize == CompletionFeed::kCaptureEntrySize);
    static_assert(guest::kMaxEntries == CompletionFeed::kMaxCaptures);
    static_assert(guest::kMaxPayload == CompletionFeed::kMaxPayload);
    static_assert(guest::kFaultStatus == CompletionFeed::kFault);
    static_assert(guest::kRecordHeadSize == CompletionFeed::kRecordSize);

    const std::vector<guest::Entry> entries = {{guest::kQueryRange, 0xCA00000000000100ull, 4, 3},
                                               {guest::kMemoryRange, 0xCA00000000000200ull, 64, 13},
                                               {guest::kQueryRange, 0xCA00000000000300ull, 0, 1}};
    const auto packet = guest::encodeWatch2(0xCA00000000000001ull, 77, entries);
    assert(CompletionFeed::watch2Size(packet.data()) == packet.size());
    uint64_t queue = 0, serial = 0;
    std::vector<CompletionFeed::Capture> captures;
    assert(CompletionFeed::parseWatch2(packet.data(), packet.size(), &queue, &serial, &captures));
    assert(queue == 0xCA00000000000001ull && serial == 77 && captures.size() == entries.size());
    for (size_t i = 0; i < entries.size(); ++i)
        assert(captures[i].kind == entries[i].kind && captures[i].handle == entries[i].handle &&
               captures[i].a == entries[i].a && captures[i].b == entries[i].b);

    // A marker that completes at once; captures as a phone's would read them.
    CompletionFeed feed([](uint64_t) -> CompletionFeed::Waiter {
        return [](const CompletionFeed::AfterFence& afterFence) -> int32_t {
            afterFence([](const CompletionFeed::Capture& c, unsigned char* out) -> int32_t {
                if (c.handle == 0xCA00000000000300ull) return 1;  // VK_NOT_READY
                if (c.kind == CompletionFeed::kCaptureQueries) {
                    for (uint64_t i = 0; i < c.b; ++i) {
                        const uint64_t value = 1000 + c.a + i, available = 1;
                        std::memcpy(out + 16 * i, &value, 8);
                        std::memcpy(out + 16 * i + 8, &available, 8);
                    }
                } else {
                    for (uint64_t i = 0; i < c.b; ++i) out[i] = uint8_t(c.a + i);
                }
                return 0;
            });
            return 0;
        };
    });
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    std::atomic_bool stop{false};
    std::thread reader([&] { assert(feed.run(pair[1], stop) == 0); });
    feed.watch(queue, serial, captures);

    // The completion record, read as the guest reads it.
    uint8_t head[guest::kRecordHeadSize];
    readExactly(pair[0], head, sizeof(head));
    uint64_t recordSerial; int32_t status; uint32_t payloadBytes;
    std::memcpy(&recordSerial, head, 8); std::memcpy(&status, head + 8, 4); std::memcpy(&payloadBytes, head + 12, 4);
    assert(recordSerial == 77 && status == 0);
    uint64_t expected = 0;
    for (const auto& e : entries) expected += guest::captureSize(e);
    assert(payloadBytes == expected);
    std::vector<uint8_t> payload(payloadBytes);
    readExactly(pair[0], payload.data(), payload.size());
    std::vector<guest::Capture> parsed;
    assert(guest::parsePayload(payload.data(), payload.size(), &parsed));
    assert(parsed.size() == 3);
    assert(parsed[0].entry == entries[0] && parsed[0].status == 0);
    for (uint64_t i = 0; i < 3; ++i) {
        uint64_t value, available;
        std::memcpy(&value, parsed[0].data + 16 * i, 8);
        std::memcpy(&available, parsed[0].data + 16 * i + 8, 8);
        assert(value == 1004 + i && available == 1);
    }
    assert(parsed[1].entry == entries[1] && parsed[1].status == 0);
    for (uint64_t i = 0; i < 13; ++i) assert(parsed[1].data[i] == uint8_t(64 + i));
    assert(parsed[2].entry == entries[2] && parsed[2].status == 1);

    // The fault record: serial 0, the fault status, opcode and result.
    feed.fault(20018u, -4);
    readExactly(pair[0], head, sizeof(head));
    std::memcpy(&recordSerial, head, 8); std::memcpy(&status, head + 8, 4); std::memcpy(&payloadBytes, head + 12, 4);
    assert(recordSerial == 0 && status == guest::kFaultStatus && payloadBytes == 8);
    uint8_t fault[8];
    readExactly(pair[0], fault, 8);
    uint32_t opcode; int32_t result;
    std::memcpy(&opcode, fault, 4); std::memcpy(&result, fault + 4, 4);
    assert(opcode == 20018u && result == -4);

    shutdown(pair[0], SHUT_WR);
    reader.join();
    ::close(pair[0]); ::close(pair[1]);
    return 0;
}
