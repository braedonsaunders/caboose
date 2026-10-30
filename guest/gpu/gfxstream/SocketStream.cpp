// SPDX-License-Identifier: MIT
#include "SocketStream.h"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

CabooseSocketStream::CabooseSocketStream(size_t size) : IOStream(size) {}
CabooseSocketStream::~CabooseSocketStream() {
    // Do not flush during teardown: an interrupted session must not send stale work.
    if (fd_ >= 0) close(fd_);
}
void CabooseSocketStream::invalidate() {
    if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
}
int CabooseSocketStream::connect(const char* path) {
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
