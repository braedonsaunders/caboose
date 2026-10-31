// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "socket_stream.h"

#include <cerrno>
#include <cstdlib>
#include <sys/socket.h>
#include <unistd.h>

namespace caboose::gpuv2 {
SocketStream::SocketStream(int fd, size_t max_buffer)
    : IOStream(4096), fd_(fd), max_buffer_(max_buffer) {
#ifdef SO_NOSIGPIPE
    int yes = 1;
    if (setsockopt(fd_, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)) != 0) fail(errno);
#endif
}
void SocketStream::fail(int value) {
    int expected = 0;
    error_.compare_exchange_strong(expected, value);
}
void* SocketStream::allocBuffer(size_t size) {
    if (error() || size > max_buffer_) { fail(EMSGSIZE); return nullptr; }
    try { buffer_.resize(size); } catch (...) { fail(ENOMEM); return nullptr; }
    return buffer_.data();
}
int SocketStream::commitBuffer(size_t size) {
    if (size > buffer_.size()) { fail(EINVAL); return -1; }
    return writeFully(buffer_.data(), size);
}
int SocketStream::writeFully(const void* data, size_t size) {
    const auto* p = static_cast<const unsigned char*>(data);
    while (size && !error()) {
#ifdef MSG_NOSIGNAL
        const auto n = send(fd_, p, size, MSG_NOSIGNAL);
#else
        const auto n = send(fd_, p, size, 0);
#endif
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { fail(n == 0 ? EPIPE : errno); break; }
        p += n; size -= static_cast<size_t>(n);
    }
    // A reply to a peer that is gone is dropped, not reported: the upstream decoder aborts
    // the process on a failed reply write. error() is set, so the decode loop ends this
    // connection after the current command.
    return 0;
}
const unsigned char* SocketStream::readRaw(void* data, size_t* size) {
    if (error()) return nullptr;
    if (!*size) return static_cast<unsigned char*>(data);
    if (eof_) { *size = 0; return nullptr; }
    ssize_t n;
    do { n = recv(fd_, data, *size, 0); } while (n < 0 && errno == EINTR);
    if (n <= 0) {
        if (n == 0) eof_ = true;
        else fail(errno);
        *size = 0;
        return nullptr;
    }
    *size = static_cast<size_t>(n);
    return static_cast<unsigned char*>(data);
}
const unsigned char* SocketStream::readFully(void* data, size_t size) {
    auto* p = static_cast<unsigned char*>(data);
    auto* start = p;
    while (size) {
        size_t n = size;
        if (!readRaw(p, &n)) {
            if (eof_) fail(EPROTO);
            return nullptr;
        }
        p += n; size -= n;
    }
    return start;
}
void* SocketStream::getDmaForReading(uint64_t) { fail(ENOTSUP); return nullptr; }
void SocketStream::unlockDma(uint64_t) { fail(ENOTSUP); }
// Snapshot state is not a portable GPU checkpoint and this transport does not
// support serializing a live socket. Refuse such use rather than invent state.
void SocketStream::onSave(gfxstream::Stream*) { std::abort(); }
unsigned char* SocketStream::onLoad(gfxstream::Stream*) { std::abort(); }
}
