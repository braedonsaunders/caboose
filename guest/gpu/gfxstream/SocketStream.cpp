// SPDX-License-Identifier: MIT
#include "SocketStream.h"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// Private diagnostic framing, not the Caboose display protocol. The peer only
// echoes this after verifying its actual immutable features and source pins.
#if defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE) && !defined(CABOOSE_GFXSTREAM_PRIVATE_ICD)
#error Private live transport requires the private diagnostic ICD build
#endif
static constexpr unsigned char kHello[48] = {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE)
    'C','B','G','L','R','E','F','1', 3,0,0,0, 0x30,0,0,0,
#else
    'C','B','G','L','R','E','F','1', 2,0,0,0, 0x10,0,0,0,
#endif
    0x20,0xd3,0xbb,0x2e,0x30,0x33,0x7c,0xab,
    0xf0,0xfe,0xbb,0x00,0x6e,0xd1,0x02,0xab,
    0x25,0xcc,0xf6,0xd9,0xdd,0xbf,0xaf,0x62,
    0x4c,0x7e,0x68,0xf9,0x04,0x09,0x69,0xc0,
};

CabooseSocketStream::CabooseSocketStream(size_t size) : IOStream(size) {}
CabooseSocketStream::~CabooseSocketStream() {
    // Do not flush during teardown: an interrupted session must not send stale work.
    if (fd_ >= 0) close(fd_);
}
void CabooseSocketStream::invalidate() {
    if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
}
int CabooseSocketStream::connect(const char* path) {
    const uint32_t nativeOne = 1;
    if (*reinterpret_cast<const unsigned char*>(&nativeOne) != 1) { errno = ENOTSUP; return -1; }
    if (!path) path = std::getenv("CABOOSE_GFXSTREAM_SOCKET");
    if (!path || !*path || fd_ >= 0) { errno = EINVAL; return -1; }
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (std::strlen(path) >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    std::strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    fd_ = fd;
    unsigned char reply[sizeof(kHello)];
    if (writeFully(kHello, sizeof(kHello)) != 0 ||
        !readFully(reply, sizeof(reply)) || std::memcmp(reply, kHello, sizeof(kHello))) {
        invalidate();
        close(fd_);
        fd_ = -1;
        errno = EPROTO;
        return -1;
    }
    return 0;
}
void* CabooseSocketStream::allocBuffer(size_t size) {
    try { buffer_.resize(size); } catch (const std::exception&) { return nullptr; }
    return buffer_.data();
}
int CabooseSocketStream::commitBuffer(size_t size) {
    if (size > buffer_.size()) { errno = EINVAL; return -1; }
    return writeFully(buffer_.data(), size);
}
int CabooseSocketStream::writeFully(const void* data, size_t len) {
    auto p = static_cast<const unsigned char*>(data);
    while (len) {
        ssize_t n = send(fd_, p, len, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { invalidate(); return -1; }
        p += n; len -= static_cast<size_t>(n);
    }
    return 0;
}
const unsigned char* CabooseSocketStream::readFully(void* data, size_t len) {
    auto p = static_cast<unsigned char*>(data);
    auto start = p;
    while (len) {
        ssize_t n = recv(fd_, p, len, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { invalidate(); return nullptr; }
        p += n; len -= static_cast<size_t>(n);
    }
    return start;
}
const unsigned char* CabooseSocketStream::commitBufferAndReadFully(size_t size, void* data, size_t len) {
    if (commitBuffer(size) != 0) return nullptr;
    return readFully(data, len);
}
const unsigned char* CabooseSocketStream::read(void* data, size_t* len) {
    if (!data || !len) { errno = EINVAL; return nullptr; }
    ssize_t n;
    do { n = recv(fd_, data, *len, 0); } while (n < 0 && errno == EINTR);
    if (n <= 0) { invalidate(); return nullptr; }
    *len = static_cast<size_t>(n);
    return static_cast<const unsigned char*>(data);
}
