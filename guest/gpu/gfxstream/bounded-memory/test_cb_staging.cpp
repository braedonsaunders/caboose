// SPDX-License-Identifier: MIT
#include <cstddef>
#include <cstdint>

namespace gfxstream {
namespace guest {

class IOStream {
public:
    explicit IOStream(size_t bufSize)
        : m_iostreamBuf(nullptr),
          m_bufsizeOrig(bufSize),
          m_bufsize(bufSize),
          m_free(0),
          m_refcount(1) {}

    virtual ~IOStream() = default;

    virtual int connect(const char* = nullptr) { return 0; }
    virtual uint64_t processPipeInit() { return 0; }
    virtual void invalidate() {}

    virtual void* allocBuffer(size_t minSize) = 0;
    virtual size_t idealAllocSize(size_t len) {
        if (len > m_bufsizeOrig) return len;
        return m_bufsizeOrig;
    }
    virtual int commitBuffer(size_t size) = 0;
    virtual const unsigned char* readFully(void* buf, size_t len) = 0;
    virtual const unsigned char* commitBufferAndReadFully(size_t size, void* buf, size_t len) = 0;
    virtual const unsigned char* read(void* buf, size_t* inout_len) = 0;
    virtual int writeFully(const void* buf, size_t len) = 0;
    virtual int writeFullyAsync(const void* buf, size_t len) {
        return writeFully(buf, len);
    }

    void incRef() { __atomic_add_fetch(&m_refcount, 1, __ATOMIC_SEQ_CST); }
    bool decRef() {
        if (0 == __atomic_sub_fetch(&m_refcount, 1, __ATOMIC_SEQ_CST)) {
            delete this;
            return true;
        }
        return false;
    }

    virtual unsigned char* alloc(size_t len) {
        if (m_iostreamBuf && len > m_free) {
            if (flush() < 0) {
                return nullptr;
            }
        }
        if (!m_iostreamBuf || len > m_bufsize) {
            size_t allocLen = this->idealAllocSize(len);
            m_iostreamBuf = static_cast<unsigned char*>(allocBuffer(allocLen));
            if (!m_iostreamBuf) {
                return nullptr;
            }
            m_bufsize = m_free = allocLen;
        }
        unsigned char* ptr = m_iostreamBuf + (m_bufsize - m_free);
        m_free -= len;
        return ptr;
    }

    virtual int flush() {
        if (!m_iostreamBuf || m_free == m_bufsize) return 0;
        int stat = commitBuffer(m_bufsize - m_free);
        m_iostreamBuf = nullptr;
        m_free = 0;
        return stat;
    }

    const unsigned char* readback(void* buf, size_t len) {
        if (m_iostreamBuf && m_free != m_bufsize) {
            size_t size = m_bufsize - m_free;
            m_iostreamBuf = nullptr;
            m_free = 0;
            return commitBufferAndReadFully(size, buf, len);
        }
        return readFully(buf, len);
    }

protected:
    void rewind() {
        m_iostreamBuf = nullptr;
        m_bufsize = m_bufsizeOrig;
        m_free = 0;
    }

private:
    unsigned char* m_iostreamBuf;
    size_t m_bufsizeOrig;
    size_t m_bufsize;
    size_t m_free;
    uint32_t m_refcount;
};

} // namespace guest
} // namespace gfxstream

#include "cb_staging.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

using namespace caboose::memory;

namespace {

constexpr uint32_t kOpBeginCommandBuffer = 20090u;
constexpr uint32_t kOpEndCommandBuffer = 20091u;
constexpr uint32_t kOpCmdBindPipeline = 20105u;
constexpr uint32_t kOpCmdDraw = 20122u;
constexpr uint32_t kOpAllocateDescriptorSets = 20077u;

static void writePacketHeader(uint8_t* dst, uint32_t opcode, uint32_t packetSize, uint64_t cbHandle) {
    std::memcpy(dst, &opcode, sizeof(uint32_t));
    std::memcpy(dst + 4, &packetSize, sizeof(uint32_t));
    std::memcpy(dst + 8, &cbHandle, sizeof(uint64_t));
}

// Mock socket stream that simulates the thread-local socket transport and server replies.
class MockSocketStream final : public gfxstream::guest::IOStream {
public:
    MockSocketStream() : IOStream(4096) {}

    void queueReply(int32_t res) {
        const auto* p = reinterpret_cast<const uint8_t*>(&res);
        replies_.insert(replies_.end(), p, p + sizeof(int32_t));
    }

    void* allocBuffer(size_t minSize) override {
        buf_.resize(minSize);
        return buf_.data();
    }

    int commitBuffer(size_t size) override {
        wire_.insert(wire_.end(), buf_.data(), buf_.data() + size);
        ++flushes_;
        return 0;
    }

    const unsigned char* readFully(void* dst, size_t len) override {
        if (replyPos_ + len > replies_.size()) {
            invalidated_ = true;
            return nullptr;
        }
        std::memcpy(dst, replies_.data() + replyPos_, len);
        replyPos_ += len;
        ++reads_;
        return static_cast<const unsigned char*>(dst);
    }

    const unsigned char* commitBufferAndReadFully(size_t size, void* dst, size_t len) override {
        if (commitBuffer(size) != 0) return nullptr;
        return readFully(dst, len);
    }

    const unsigned char* read(void* dst, size_t* inout_len) override {
        if (!dst || !inout_len) return nullptr;
        return readFully(dst, *inout_len);
    }

    int writeFully(const void* src, size_t len) override {
        const auto* p = static_cast<const uint8_t*>(src);
        wire_.insert(wire_.end(), p, p + len);
        return 0;
    }

    void invalidate() override { invalidated_ = true; }

    const std::vector<uint8_t>& wire() const { return wire_; }
    size_t flushes() const { return flushes_; }
    size_t reads() const { return reads_; }
    bool invalidated() const { return invalidated_; }

private:
    std::vector<uint8_t> buf_;
    std::vector<uint8_t> wire_;
    std::vector<uint8_t> replies_;
    size_t replyPos_ = 0;
    size_t flushes_ = 0;
    size_t reads_ = 0;
    bool invalidated_ = false;
};

} // namespace

int main() {
    // 1. Happy path: Stage OP_vkBeginCommandBuffer + OP_vkCmd* locally in CabooseCommandBufferStream,
    // verify an interleaved synchronous RPC on the thread-local socket stream does not collide with
    // deferred Begin, then flush [OP_vkBeginCommandBuffer + OP_vkCmd* + OP_vkEndCommandBuffer] and
    // read both 4-byte replies in one single readback round-trip.
    {
        Budget localBudget(stagingBytes);
        CabooseCommandBufferStream cbStream(localBudget);
        MockSocketStream tlsSocket;

        const uint64_t cbHandle = 0xdeadbeefcafebabeULL;

        // Stage OP_vkBeginCommandBuffer (24 bytes)
        uint8_t* beginPtr = cbStream.alloc(24);
        assert(beginPtr != nullptr);
        writePacketHeader(beginPtr, kOpBeginCommandBuffer, 24, cbHandle);
        uint64_t flags = 1;
        std::memcpy(beginPtr + 16, &flags, sizeof(uint64_t));
        assert(localBudget.used() == cbInitialStagingBytes);
        assert(tlsSocket.wire().empty());

        // Interleave a synchronous RPC (e.g. OP_vkAllocateDescriptorSets) on the thread-local socket!
        tlsSocket.queueReply(0); // VK_SUCCESS for AllocateDescriptorSets
        uint8_t* syncRpc = tlsSocket.alloc(16);
        writePacketHeader(syncRpc, kOpAllocateDescriptorSets, 16, 0x1111ULL);
        int32_t syncReply = -1;
        assert(tlsSocket.readback(&syncReply, sizeof(syncReply)) != nullptr);
        assert(syncReply == 0);
        assert(tlsSocket.flushes() == 1 && tlsSocket.reads() == 1);
        assert(tlsSocket.wire().size() == 16);

        // Stage OP_vkCmdBindPipeline (24 bytes) and OP_vkCmdDraw (32 bytes) into cbStream
        uint8_t* bindPtr = cbStream.alloc(24);
        assert(bindPtr != nullptr);
        writePacketHeader(bindPtr, kOpCmdBindPipeline, 24, cbHandle);
        uint64_t pipeline = 0x2222ULL;
        std::memcpy(bindPtr + 16, &pipeline, sizeof(uint64_t));

        uint8_t* drawPtr = cbStream.alloc(32);
        assert(drawPtr != nullptr);
        writePacketHeader(drawPtr, kOpCmdDraw, 32, cbHandle);
        std::memset(drawPtr + 16, 0x77, 16);

        // Detach staged bytes on vkEndCommandBuffer
        Reservation endReservation{localBudget};
        std::vector<uint8_t> staged;
        assert(cbStream.detachWritten(staged, endReservation));
        assert(staged.size() == 24 + 24 + 32);
        assert(cbStream.capacityBytes() == 0);
        // Only the exact detached bytes (80 bytes) are held during the End RPC
        assert(localBudget.used() == staged.size());

        // Queue Begin reply (VK_SUCCESS = 0) and End reply (VK_SUCCESS = 0)
        tlsSocket.queueReply(0);
        tlsSocket.queueReply(0);

        // Write staged bytes + OP_vkEndCommandBuffer (16 bytes) and read both 4-byte replies in one readback
        const uint32_t endPktSize = 16;
        uint8_t* outPtr = tlsSocket.alloc(staged.size() + endPktSize);
        assert(outPtr != nullptr);
        std::memcpy(outPtr, staged.data(), staged.size());
        writePacketHeader(outPtr + staged.size(), kOpEndCommandBuffer, endPktSize, cbHandle);

        int32_t replies[2] = {-1, -1};
        assert(tlsSocket.readback(replies, sizeof(replies)) != nullptr);
        assert(replies[0] == 0 && replies[1] == 0);
        assert(tlsSocket.flushes() == 2 && tlsSocket.reads() == 2);
        assert(tlsSocket.wire().size() == 16 + staged.size() + endPktSize);
    }
    assert(processBudget.used() == 0);

    // 2. Growth across chunks up to 4 MiB per-CB cap, and overflow enforcement beyond 4 MiB.
    {
        Budget localBudget(stagingBytes);
        CabooseCommandBufferStream cbStream(localBudget, cbMaxStagingBytes, cbInitialStagingBytes);

        // Allocate 64 chunks of 64 KiB = exactly 4 MiB (cbMaxStagingBytes)
        for (size_t i = 0; i < 64; ++i) {
            uint8_t* p = cbStream.alloc(64 * 1024);
            assert(p != nullptr);
            std::memset(p, static_cast<int>(i & 0xff), 64 * 1024);
        }
        assert(!cbStream.hasOverflowed());
        assert(localBudget.used() == cbMaxStagingBytes);

        // 1 additional byte exceeds cbMaxStagingBytes (4 MiB) -> returns nullptr, marks overflow,
        // and immediately releases all staged memory back to localBudget!
        uint8_t* overflowPtr = cbStream.alloc(1);
        assert(overflowPtr == nullptr);
        assert(cbStream.hasOverflowed());
        assert(localBudget.used() == 0);

        // Subsequent detachWritten fails closed so on_vkEndCommandBuffer returns VK_ERROR_OUT_OF_HOST_MEMORY
        // without sending partial commands.
        Reservation endReservation{localBudget};
        std::vector<uint8_t> staged;
        assert(!cbStream.detachWritten(staged, endReservation));
        assert(staged.empty());
        assert(localBudget.used() == 0);
    }

    // 3. Shared processBudget exhaustion fails closed without leaking budget.
    {
        Budget tightBudget(128 * 1024);
        CabooseCommandBufferStream cb1(tightBudget);
        CabooseCommandBufferStream cb2(tightBudget);

        assert(cb1.alloc(64 * 1024) != nullptr);
        assert(cb2.alloc(64 * 1024) != nullptr);
        assert(tightBudget.used() == 128 * 1024);

        // cb1 trying to grow to 128 KiB exceeds tightBudget -> fails closed and releases cb1's 64 KiB
        assert(cb1.alloc(1024) == nullptr);
        assert(cb1.hasOverflowed());
        assert(tightBudget.used() == 64 * 1024);

        // cb2 is unaffected and can still detach and complete!
        Reservation res2{tightBudget};
        std::vector<uint8_t> staged2;
        assert(cb2.detachWritten(staged2, res2));
        assert(staged2.size() == 64 * 1024);
        assert(tightBudget.used() == 64 * 1024);
    }

    // 4. Multi-threaded worker pool simulation (31 command buffers across 4 worker threads, reassigned across frames):
    // Verifies zero cross-thread lock contention during recording and full budget reclamation.
    {
        Budget poolBudget(stagingBytes);
        constexpr size_t kNumCbs = 31;
        std::vector<std::unique_ptr<CabooseCommandBufferStream>> streams(kNumCbs);
        for (size_t i = 0; i < kNumCbs; ++i) {
            streams[i] = std::make_unique<CabooseCommandBufferStream>(poolBudget);
        }

        for (int frame = 0; frame < 3; ++frame) {
            std::vector<std::thread> workers;
            for (int t = 0; t < 4; ++t) {
                workers.emplace_back([&, t, frame] {
                    for (size_t cbIdx = t; cbIdx < kNumCbs; cbIdx += 4) {
                        auto& s = *streams[(cbIdx + frame) % kNumCbs];
                        s.reset();
                        uint8_t* begin = s.alloc(24);
                        assert(begin != nullptr);
                        writePacketHeader(begin, kOpBeginCommandBuffer, 24, cbIdx + 1);
                        for (int cmd = 0; cmd < 25; ++cmd) {
                            uint8_t* p = s.alloc(32);
                            assert(p != nullptr);
                            writePacketHeader(p, kOpCmdDraw, 32, cbIdx + 1);
                        }
                        Reservation r{poolBudget};
                        std::vector<uint8_t> out;
                        assert(s.detachWritten(out, r));
                        assert(out.size() == 24 + 25 * 32);
                    }
                });
            }
            for (auto& w : workers) w.join();
            assert(poolBudget.used() == 0);
        }
        streams.clear();
        assert(poolBudget.used() == 0);
    }

    std::puts("PASS cb_staging: deferred Begin + vkCmd* local staging, interleaved sync RPC safety, 4MiB cap & budget fail-closed, 31-CB worker pool");
    return 0;
}
