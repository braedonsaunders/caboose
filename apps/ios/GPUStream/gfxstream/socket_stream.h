// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#pragma once

#include <atomic>
#include <cstddef>
#include <vector>
#include "gfxstream/host/iostream.h"

namespace caboose::gpuv2 {
// One decoder thread owns this object. The caller owns fd and may interrupt
// blocking I/O with shutdown(fd, SHUT_RDWR); it must keep fd open until return.
class SocketStream final : public gfxstream::IOStream {
public:
    explicit SocketStream(int fd, size_t max_buffer);
    void* allocBuffer(size_t size) override;
    int commitBuffer(size_t size) override;
    int writeFully(const void* data, size_t size) override;
    const unsigned char* readFully(void* data, size_t size) override;
    void* getDmaForReading(uint64_t) override;
    void unlockDma(uint64_t) override;
    int error() const { return error_.load(); }
protected:
    const unsigned char* readRaw(void* data, size_t* size) override;
    void onSave(gfxstream::Stream*) override;
    unsigned char* onLoad(gfxstream::Stream*) override;
private:
    void fail(int error);
    int fd_;
    size_t max_buffer_;
    std::vector<unsigned char> buffer_;
    std::atomic<int> error_{0};
};
}
