// SPDX-License-Identifier: MIT
#include "deferred_replies.h"
#include "silent_success.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

using namespace caboose;

namespace {
// Replies the device wrote, as raw bytes.
struct ByteStream {
    std::vector<uint8_t> bytes;
    size_t next = 0;
    bool invalidated = false;
    template <class T> void put(T value) {
        const auto* raw = reinterpret_cast<const uint8_t*>(&value);
        bytes.insert(bytes.end(), raw, raw + sizeof(value));
    }
    bool tryRead(void* out, size_t size) {
        if (bytes.size() - next < size) return false;
        std::memcpy(out, bytes.data() + next, size);
        next += size;
        return true;
    }
    void invalidate() { invalidated = true; }
};

// A feed stream's bytes.
struct Feed {
    std::vector<uint8_t> bytes;
    size_t next = 0;
    template <class T> void put(T value) {
        const auto* raw = reinterpret_cast<const uint8_t*>(&value);
        bytes.insert(bytes.end(), raw, raw + sizeof(value));
    }
    void header(uint64_t serial, int32_t status, uint32_t payloadBytes) {
        put(serial); put(status); put(payloadBytes);
    }
    bool read(void* out, size_t size) {
        if (bytes.size() - next < size) return false;
        std::memcpy(out, bytes.data() + next, size);
        next += size;
        return true;
    }
};
bool nextRecord(Feed& feed, silent::Record& record) {
    return silent::readRecord([&](void* out, size_t size) { return feed.read(out, size); }, record);
}
}  // namespace

int main() {
    // REPLY_MODE's wire form: opcode, size 16, mode 1, reserved 0.
    uint8_t packet[silent::kReplyModePacketSize];
    silent::encodeReplyMode(packet);
    const uint8_t expected[] = {0x06, 0xFE, 0x42, 0x43, 16, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0};
    assert(std::memcmp(packet, expected, sizeof(expected)) == 0);

    // The listed commands, and none of the others the guest defers or waits for.
    assert(silent::silentOpcode(20018) && silent::silentOpcode(20050) && silent::silentOpcode(275454371u));
    assert(silent::silentOpcode(20090) && silent::silentOpcode(20091));  // command buffer begin and end
    assert(!silent::silentOpcode(20092));  // vkResetCommandBuffer
    assert(!silent::silentOpcode(20034) && !silent::silentOpcode(20036));  // flush, fence reset
    assert(!silent::silentOpcode(0));

    // A completion record with no payload, one with a payload this process does not read, and a
    // FAULT, in one feed.
    {
        Feed feed;
        feed.header(7, 0, 0);
        feed.header(8, 0, 300);
        feed.bytes.insert(feed.bytes.end(), 300, 0xEE);
        feed.header(silent::kFaultSerial, silent::kFaultStatus, 8);
        feed.put(uint32_t(20050)); feed.put(int32_t(-2));
        feed.header(9, -4, 0);
        silent::Record record;
        assert(nextRecord(feed, record) && record.kind == silent::Record::Kind::Completion &&
               record.serial == 7 && record.status == 0);
        assert(nextRecord(feed, record) && record.kind == silent::Record::Kind::Other && record.serial == 8);
        assert(nextRecord(feed, record) && record.kind == silent::Record::Kind::Fault &&
               record.opcode == 20050 && record.result == -2);
        assert(nextRecord(feed, record) && record.kind == silent::Record::Kind::Completion &&
               record.serial == 9 && record.status == -4);
        assert(!nextRecord(feed, record));  // the feed ended
    }
    // A FAULT whose payload is not 8 bytes, a payload past the bound, and a record cut short are
    // protocol errors.
    {
        Feed wrongSize;
        wrongSize.header(silent::kFaultSerial, silent::kFaultStatus, 4);
        wrongSize.put(uint32_t(20050));
        silent::Record record;
        assert(!nextRecord(wrongSize, record));
        Feed huge;
        huge.header(3, 0, silent::kMaxRecordPayload + 1);
        assert(!nextRecord(huge, record));
        Feed cut;
        cut.header(3, 0, 16);
        cut.put(uint64_t(1));
        assert(!nextRecord(cut, record));
        // A record serial 0 with another status is not a fault (an ordinary zero-serial record).
        Feed other;
        other.header(0, 0, 0);
        assert(nextRecord(other, record) && record.kind == silent::Record::Kind::Completion);
    }

    auto& mode = silent::replyMode();
    int a = 0, b = 0, device = 0, staging = 0, recorder = 0;
    mode.deviceStream(&device, true);
    mode.encoderMade(&a, &device);
    mode.encoderMade(&b, &device);
    mode.encoderMade(&recorder, &staging);
    // Nothing switches before the grant, before the feed runs, or after the executor left.
    assert(!mode.due(&a, true) && !mode.silent(&a));
    mode.granted(true);
    assert(!mode.due(&a, false) && !mode.silent(&a));
    completion::executorLost.store(true);
    assert(!mode.due(&a, true));
    completion::executorLost.store(false);
    // Once per stream and connection generation.
    assert(mode.due(&a, true) && mode.silent(&a) && !mode.silent(&b) && mode.anySilent());
    assert(!mode.due(&a, true));
    // An encoder recording a command buffer locally never switches.
    assert(!mode.due(&recorder, true) && !mode.silent(&recorder));

    // A silent stream queues no reply for a listed create, nor for a staged submit: its command
    // buffers' begins and ends and the submit itself.
    {
        memory::DeferredReplies table;
        memory::lastOpcode = 20050;  // vkCreateBuffer
        table.addHandleCreate(&a, 0xCA00000100000001ull, 64);
        assert(table.pending() == 0);
        assert(mode.takeUnconfirmed(&a) && !mode.takeUnconfirmed(&a));
        memory::lastOpcode = 20018;  // vkQueueSubmit with two staged command buffers
        table.addCheckedResults(&a, 5, 4096);
        assert(table.pending() == 0);
        memory::lastOpcode = 20028;  // vkBindBufferMemory
        table.addCheckedResult(&a, 32);
        assert(table.pending() == 0);
        // A command not listed still queues its reply, and so does the same command on a stream
        // that has not switched.
        memory::lastOpcode = 20036;  // vkResetFences
        table.addCheckedResult(&a, 32);
        assert(table.pending() == 1);
        memory::lastOpcode = 20050;
        table.addHandleCreate(&b, 0xCA00000100000002ull, 64);
        assert(table.pending() == 2 && !mode.takeUnconfirmed(&b));
        // The drain reads only what the device writes: the reset's result.
        ByteStream replies;
        replies.put(int32_t(0));
        assert(table.drain(&a, &replies) && replies.next == replies.bytes.size() && !replies.invalidated);
        assert(table.pending() == 1);
        ByteStream created;
        created.put(uint64_t(0xCA00000100000002ull)); created.put(int32_t(0));
        assert(table.drain(&b, &created) && table.pending() == 0);
        memory::lastOpcode = 0;
    }
    // Silent commands never count against the bounds: past 6 MiB of them nothing is drained.
    {
        memory::DeferredReplies bounded;
        ByteStream none;
        memory::lastOpcode = 20018;
        for (int i = 0; i < 16; ++i) {
            assert(bounded.reserve(&a, &none, 1024 * 1024));
            bounded.addCheckedResult(&a, 1024 * 1024);
        }
        assert(bounded.pending() == 0 && none.next == 0);
        memory::lastOpcode = 0;
    }

    // A new executor connection: the stream switches again before its next silent command, and
    // until then its replies are queued.
    completion::connectionGeneration.fetch_add(1);
    assert(!mode.silent(&a) && !mode.anySilent());
    {
        memory::DeferredReplies table;
        memory::lastOpcode = 20050;
        table.addHandleCreate(&a, 0xCA00000200000001ull, 64);
        assert(table.pending() == 1);
        memory::lastOpcode = 0;
    }
    assert(mode.due(&a, true) && mode.silent(&a));

    // The feed ending after the process closed its own device stream (vkDestroyDevice, exit) is
    // teardown, not a loss: no stream it could fault is open. While the stream is open it is.
    assert(mode.anySilent());
    mode.deviceStream(&device, false);
    assert(mode.silent(&a) && !mode.anySilent());
    mode.deviceStream(&device, true);
    assert(mode.anySilent());

    // A gone encoder forgets its switch; its address made again on a device stream starts over.
    mode.encoderGone(&a);
    assert(!mode.silent(&a));
    mode.encoderMade(&a, &device);
    assert(mode.due(&a, true));
    // A FAULT is the loss of the process's device.
    assert(!completion::executorLost.load());
    silent::fault(20065, -3);
    assert(completion::executorLost.load());
    assert(!mode.due(&b, true));
    std::printf("silent success: ok\n");
}
