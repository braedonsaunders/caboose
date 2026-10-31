// SPDX-License-Identifier: MIT
//
// Registration of phone-resident dma-bufs with the GPU broker (docs/gpu-buffers.md), so
// the compositor can show one a window commits: CGLS kind 40 names the image holding a
// buffer's pixels and carries the dma-buf itself; kind 41 forgets it. One connection per
// process to the private surface socket, opened on first use; closing it forgets all of
// the process's buffers. Without the socket nothing is registered and buffers still work
// within the process.
#pragma once

#if defined(__linux__)

#include <cerrno>
#include <cstdint>
#include <cstdlib>
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
        if (!connectLocked()) return false;
        std::vector<uint8_t> packet = {'C', 'G', 'L', 'S', 1, 0, uint8_t(kind), uint8_t(kind >> 8)};
        put32(packet, uint32_t(16 + body.size()));
        put32(packet, 0);
        packet.insert(packet.end(), body.begin(), body.end());
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
        if (sent == ssize_t(packet.size())) return true;
        // The broker refused a record or went away: stop registering for this process.
        close(socket_);
        socket_ = -1;
        failed_ = true;
        return false;
    }

    bool connectLocked() {
        if (socket_ >= 0) return true;
        if (failed_) return false;
        failed_ = true;  // One attempt per process.
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
        failed_ = false;
        return true;
    }

    std::mutex mutex_;
    int socket_ = -1;
    bool failed_ = false;
};

inline Registrations& registrations() {
    static Registrations* instance = new Registrations();  // Outlives static destructors.
    return *instance;
}

}  // namespace caboose::dmabuf

#endif  // __linux__
