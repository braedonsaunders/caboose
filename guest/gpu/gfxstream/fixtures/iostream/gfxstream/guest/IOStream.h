// SPDX-License-Identifier: MIT
// The part of Mesa's gfxstream guest IOStream interface (with the driver series'
// invalidate()) that SocketStream implements, for unit tests outside a Mesa tree.
#pragma once
#include <cstddef>
#include <cstdint>

namespace gfxstream::guest {
class IOStream {
public:
    explicit IOStream(size_t) {}
    virtual ~IOStream() = default;
    virtual int connect(const char* = nullptr) { return 0; }
    virtual void invalidate() {}
    virtual void* allocBuffer(size_t minSize) = 0;
    virtual int commitBuffer(size_t size) = 0;
    virtual const unsigned char* readFully(void* buf, size_t len) = 0;
    virtual const unsigned char* commitBufferAndReadFully(size_t size, void* buf, size_t len) = 0;
    virtual const unsigned char* read(void* buf, size_t* inout_len) = 0;
    virtual int writeFully(const void* buf, size_t len) = 0;
};
}  // namespace gfxstream::guest
