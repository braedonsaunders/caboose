// SPDX-License-Identifier: MIT
// An ordered local transport for Mesa's gfxstream guest IOStream.
#pragma once

#include "gfxstream/guest/IOStream.h"
#include <atomic>
#include <cstddef>
#include <vector>

class CabooseSocketStream final : public gfxstream::guest::IOStream {
public:
    explicit CabooseSocketStream(size_t bufferSize);
    ~CabooseSocketStream() override;
    int connect(const char* path = nullptr) override;
    void invalidate() override;
    void* allocBuffer(size_t size) override;
    int commitBuffer(size_t size) override;
    const unsigned char* readFully(void* buf, size_t len) override;
    const unsigned char* commitBufferAndReadFully(size_t size, void* buf, size_t len) override;
    const unsigned char* read(void* buf, size_t* len) override;
    int writeFully(const void* buf, size_t len) override;
    bool indexedHandshakeReady() const { return indexedReady_.load(std::memory_order_acquire); }
private:
    std::atomic<bool> indexedReady_{false};
    int fd_ = -1;
    std::vector<unsigned char> buffer_;
};
