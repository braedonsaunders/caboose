// SPDX-License-Identifier: MIT
//
// Registration of phone-resident dma-bufs with the GPU broker (docs/gpu-buffers.md), so
// the compositor can show one a window commits: CGLS kind 40 names the image holding a
// buffer's pixels and carries the dma-buf itself; kind 41 forgets it. One connection per
// process to the private surface socket, opened on first use; closing it forgets all of
// the process's buffers. The broker closes it when the process's executor is lost, and the
// next registration opens a new one: a process that recovers from the loss registers the
// buffers it makes on the new executor. Without the socket nothing is registered (a failed
// connection is tried again at most once a second) and buffers still work within the
// process.
#pragma once

#if defined(__linux__)

#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <chrono>
#include <cstring>
#include <mutex>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

#include "dmabuf.h"

namespace caboose::dmabuf {

struct RegisteredImage {
    uint64_t instance, device, queue, image;  // host (boxed) handles
    uint32_t format, width, height, queueFamily;
};

class Registrations {
public:
    // Registers the image of the buffer behind `fd`. False if it could not be sent.
    bool add(int fd, const RegisteredImage& image) {
        std::vector<uint8_t> body;
        put64(body, image.instance); put64(body, image.device); put64(body, image.queue); put64(body, image.image);
        put32(body, image.format); put32(body, image.width); put32(body, image.height); put32(body, image.queueFamily);
        return send(40, body, fd);
    }

    bool forget(const Identity& identity) {
        std::vector<uint8_t> body;
        put64(body, identity.device); put64(body, identity.inode);
        return send(41, body, -1);
    }

private:
    static void put32(std::vector<uint8_t>& b, uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back(uint8_t(v >> (8 * i))); }
    static void put64(std::vector<uint8_t>& b, uint64_t v) { put32(b, uint32_t(v)); put32(b, uint32_t(v >> 32)); }

    bool send(uint16_t kind, const std::vector<uint8_t>& body, int fd) {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<uint8_t> packet = {'C', 'G', 'L', 'S', 1, 0, uint8_t(kind), uint8_t(kind >> 8)};
        put32(packet, uint32_t(16 + body.size()));
        put32(packet, 0);
        packet.insert(packet.end(), body.begin(), body.end());
        // A connection the broker closed fails the first send; a registration is then sent
        // again on a new connection. A forget is not: the closed connection forgot it.
        for (int attempt = 0; attempt < (kind == 40 ? 2 : 1); ++attempt) {
            const bool fresh = socket_ < 0;
            if (!connectLocked()) return false;
            if (sendLocked(packet, fd)) return true;
            close(socket_);
            socket_ = -1;
            if (fresh) break;  // A new connection that fails at once is not retried now.
        }
        return false;
    }

    bool sendLocked(std::vector<uint8_t>& packet, int fd) {
        iovec io{packet.data(), packet.size()};
        msghdr message{};
        message.msg_iov = &io;
        message.msg_iovlen = 1;
        alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))] = {};
        if (fd >= 0) {
            message.msg_control = control;
            message.msg_controllen = sizeof(control);
            cmsghdr* header = CMSG_FIRSTHDR(&message);
            header->cmsg_level = SOL_SOCKET;
            header->cmsg_type = SCM_RIGHTS;
            header->cmsg_len = CMSG_LEN(sizeof(int));
            std::memcpy(CMSG_DATA(header), &fd, sizeof(int));
        }
        ssize_t sent;
        do sent = sendmsg(socket_, &message, MSG_NOSIGNAL);
        while (sent < 0 && errno == EINTR);
        return sent == ssize_t(packet.size());
    }

    bool connectLocked() {
        if (socket_ >= 0) return true;
        const auto now = std::chrono::steady_clock::now();
        if (now < nextConnect_) return false;
        nextConnect_ = now + kConnectRetry;
        const char* path = std::getenv("CABOOSE_GFXSTREAM_SURFACE_SOCKET");
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        if (!path || !*path || std::strlen(path) >= sizeof(address.sun_path)) return false;
        std::strcpy(address.sun_path, path);
        const int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
        if (fd < 0) return false;
        if (connect(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
            close(fd);
            return false;
        }
        socket_ = fd;
        nextConnect_ = {};
        return true;
    }

    static constexpr std::chrono::seconds kConnectRetry{1};
    std::mutex mutex_;
    int socket_ = -1;
    std::chrono::steady_clock::time_point nextConnect_{};
};

inline Registrations& registrations() {
    static Registrations* instance = new Registrations();  // Outlives static destructors.
    return *instance;
}

}  // namespace caboose::dmabuf

#endif  // __linux__
