// SPDX-License-Identifier: MIT
//
// Registration of phone-resident dma-bufs with the GPU broker (docs/gpu-buffers.md), so
// the compositor can show one a window commits: CGLS kind 40 names the image holding a
// buffer's pixels and carries the dma-buf itself; kind 41 forgets it. One connection per
// process to the private surface socket; closing it forgets all of the process's buffers.
//
// Registrations belong to the broker session (executor generation) they were made under,
// which the broker's device socket identifies: the broker makes that socket for each
// executor it admits and removes it when the executor leaves. The process keeps the
// registrations of its live buffers, and every new connection first sends those of the
// current session again, so a connection the broker closed (or one that could not be made
// for a moment) loses nothing; registrations of an earlier session are dropped, since their
// images went with their executor. Without the socket nothing is registered and buffers
// still work within the process.
#pragma once

#if defined(__linux__)

#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <sys/socket.h>
#include <sys/stat.h>
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
    // Registers the image of the buffer behind `fd` (the caller keeps `fd`). False if it
    // could not be sent now; it is sent with the next connection of the same session.
    bool add(int fd, const RegisteredImage& image) {
        const auto identity = identify(fd);
        return identity && add(fd, *identity, image);
    }
    bool add(int fd, const Identity& identity, const RegisteredImage& image) {
        std::vector<uint8_t> body;
        put64(body, image.instance); put64(body, image.device); put64(body, image.queue); put64(body, image.image);
        put32(body, image.format); put32(body, image.width); put32(body, image.height); put32(body, image.queueFamily);
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t session = currentSession();
        dropOtherSessions(session);
        if (live_.count(identity)) return true;  // A buffer is registered once, for its first image.
        const int kept = fcntl(fd, F_DUPFD_CLOEXEC, 0);
        if (kept < 0) return false;
        live_[identity] = Live{kept, body, session};
        return sendLocked(packet(40, body), kept, session);
    }

    bool forget(const Identity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = live_.find(identity);
        if (found == live_.end()) return true;
        ::close(found->second.fd);
        const uint64_t session = found->second.session;
        live_.erase(found);
        // A forget is sent only on the connection that holds the registration; a closed
        // connection forgot it already.
        if (socket_ < 0 || socketSession_ != session) return true;
        std::vector<uint8_t> body;
        put64(body, identity.device); put64(body, identity.inode);
        const auto bytes = packet(41, body);
        if (writeLocked(bytes, -1)) return true;
        closeLocked();
        return false;
    }

    // Registrations kept for buffers that are still live.
    size_t size() {
        std::lock_guard<std::mutex> lock(mutex_);
        return live_.size();
    }

private:
    struct Live {
        int fd;
        std::vector<uint8_t> body;
        uint64_t session;
    };

    static void put32(std::vector<uint8_t>& b, uint32_t v) { for (int i = 0; i < 4; ++i) b.push_back(uint8_t(v >> (8 * i))); }
    static void put64(std::vector<uint8_t>& b, uint64_t v) { put32(b, uint32_t(v)); put32(b, uint32_t(v >> 32)); }
    static std::vector<uint8_t> packet(uint16_t kind, const std::vector<uint8_t>& body) {
        std::vector<uint8_t> packet = {'C', 'G', 'L', 'S', 1, 0, uint8_t(kind), uint8_t(kind >> 8)};
        put32(packet, uint32_t(16 + body.size()));
        put32(packet, 0);
        packet.insert(packet.end(), body.begin(), body.end());
        return packet;
    }

    // The broker session now: its device socket's inode and change time (0 without one).
    static uint64_t currentSession() {
        const char* path = std::getenv("CABOOSE_GFXSTREAM_SOCKET");
        struct stat info;
        if (!path || !*path || stat(path, &info) != 0 || !S_ISSOCK(info.st_mode)) return 0;
        const uint64_t changed = uint64_t(info.st_ctim.tv_sec) * 1000000000ull + uint64_t(info.st_ctim.tv_nsec);
        return (uint64_t(info.st_ino) * 1000003ull) ^ changed ^ 1;
    }

    void dropOtherSessions(uint64_t session) {
        for (auto it = live_.begin(); it != live_.end();) {
            if (it->second.session == session) { ++it; continue; }
            ::close(it->second.fd);
            it = live_.erase(it);
        }
        if (socket_ >= 0 && socketSession_ != session) closeLocked();
    }

    // Sends one registration, connecting (and sending the session's others first) if needed.
    bool sendLocked(const std::vector<uint8_t>& bytes, int fd, uint64_t session) {
        for (int attempt = 0; attempt < 2; ++attempt) {
            const bool fresh = socket_ < 0;
            if (fresh && !connectLocked(session)) return false;  // Sent with the next connection.
            if (fresh) return true;  // connectLocked sent every live registration, this one included.
            if (writeLocked(bytes, fd)) return true;
            closeLocked();  // The broker closed it (the executor was lost): connect again.
        }
        return false;
    }

    bool writeLocked(const std::vector<uint8_t>& bytes, int fd) {
        iovec io{const_cast<uint8_t*>(bytes.data()), bytes.size()};
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
        return sent == ssize_t(bytes.size());
    }

    void closeLocked() {
        if (socket_ >= 0) ::close(socket_);
        socket_ = -1;
    }

    // A new connection for `session`, with every live registration of it sent on it.
    bool connectLocked(uint64_t session) {
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
            ::close(fd);
            return false;
        }
        socket_ = fd;
        socketSession_ = session;
        for (const auto& entry : live_) {
            if (entry.second.session != session) continue;
            if (!writeLocked(packet(40, entry.second.body), entry.second.fd)) {
                closeLocked();
                return false;
            }
        }
        nextConnect_ = {};
        return true;
    }

    // A connection that could not be made is tried again after this, by the next record.
    static constexpr std::chrono::milliseconds kConnectRetry{250};

    std::mutex mutex_;
    std::map<Identity, Live> live_;
    int socket_ = -1;
    uint64_t socketSession_ = 0;
    std::chrono::steady_clock::time_point nextConnect_{};
};

inline Registrations& registrations() {
    static Registrations* instance = new Registrations();  // Outlives static destructors.
    return *instance;
}

}  // namespace caboose::dmabuf

#endif  // __linux__
