// SPDX-License-Identifier: MIT
//
// Registrations against a stand-in broker: the first registration connects; a connection
// the broker closed is replaced by the next record, which first sends again every live
// registration of the session; registrations made while the socket was missing arrive with
// the next connection; a new broker session (a new executor) drops the previous session's.
#include "registration.h"

#include <cstdio>
#include <cstdlib>
#include <set>
#include <string>
#include <sys/mman.h>
#include <thread>

using caboose::dmabuf::Identity;
using caboose::dmabuf::RegisteredImage;
using caboose::dmabuf::Registrations;

static int failures = 0;
#define CHECK(condition)                                                         \
    do {                                                                         \
        if (!(condition)) {                                                      \
            std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
            ++failures;                                                          \
        }                                                                        \
    } while (0)

static int listenAt(const std::string& path, int type = SOCK_SEQPACKET) {
    const int fd = socket(AF_UNIX, type | SOCK_CLOEXEC, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strcpy(address.sun_path, path.c_str());
    unlink(path.c_str());
    if (fd < 0 || bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(fd, 4)) return -1;
    return fd;
}

// The records waiting on an accepted connection: (kind, image handle or inode).
static std::vector<std::pair<uint16_t, uint64_t>> drain(int connection) {
    std::vector<std::pair<uint16_t, uint64_t>> records;
    for (;;) {
        uint8_t data[256];
        iovec io{data, sizeof(data)};
        alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))] = {};
        msghdr message{};
        message.msg_iov = &io;
        message.msg_iovlen = 1;
        message.msg_control = control;
        message.msg_controllen = sizeof(control);
        const ssize_t got = recvmsg(connection, &message, MSG_DONTWAIT);
        if (got < 16 || std::memcmp(data, "CGLS", 4)) return records;
        const uint16_t kind = uint16_t(data[6] | data[7] << 8);
        uint64_t value = 0;
        std::memcpy(&value, data + (kind == 40 ? 16 + 24 : 16 + 8), sizeof(value));  // image / inode
        for (cmsghdr* header = CMSG_FIRSTHDR(&message); header; header = CMSG_NXTHDR(&message, header)) {
            int fd;
            std::memcpy(&fd, CMSG_DATA(header), sizeof(fd));
            close(fd);
        }
        records.emplace_back(kind, value);
    }
}

static RegisteredImage image(uint64_t handle) { return RegisteredImage{1, 2, 3, handle, 44, 640, 480, 0}; }

int main() {
    char directory[] = "/tmp/caboose-registration-XXXXXX";
    if (!mkdtemp(directory)) return 1;
    const std::string surface = std::string(directory) + "/surface.sock";
    const std::string device = std::string(directory) + "/gpu.sock";
    setenv("CABOOSE_GFXSTREAM_SURFACE_SOCKET", surface.c_str(), 1);
    setenv("CABOOSE_GFXSTREAM_SOCKET", device.c_str(), 1);
    const int buffer = memfd_create("buffer", MFD_CLOEXEC);
    int session = listenAt(device, SOCK_STREAM);  // The broker's first session.

    // No surface socket yet: the registration is kept, not sent.
    Registrations registrations;
    CHECK(!registrations.add(buffer, Identity{1, 11}, image(101)));
    CHECK(registrations.size() == 1);
    const int listener = listenAt(surface);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));

    // The next registration connects and sends both, each with its dma-buf.
    CHECK(registrations.add(buffer, Identity{1, 12}, image(102)));
    int first = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
    CHECK(first >= 0);
    auto records = drain(first);
    CHECK(records.size() == 2 && records[0] == std::make_pair(uint16_t(40), uint64_t(101)) &&
          records[1] == std::make_pair(uint16_t(40), uint64_t(102)));
    // A buffer is registered once.
    CHECK(registrations.add(buffer, Identity{1, 12}, image(999)));
    CHECK(drain(first).empty());
    CHECK(registrations.forget(Identity{1, 11}));
    records = drain(first);
    CHECK(records.size() == 1 && records[0] == std::make_pair(uint16_t(41), uint64_t(11)));

    // The broker closes the connection: the next record goes out on a new one, after the
    // session's live registrations.
    close(first);
    CHECK(registrations.add(buffer, Identity{1, 13}, image(103)));
    int second = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
    CHECK(second >= 0);
    records = drain(second);
    CHECK(records.size() == 2 && records[0].second == 102 && records[1].second == 103);

    // A new broker session (a new executor): the previous session's registrations are
    // dropped and the connection is replaced; only the new registration is sent.
    close(session);
    session = listenAt(device, SOCK_STREAM);
    CHECK(registrations.add(buffer, Identity{1, 14}, image(104)));
    int third = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
    CHECK(third >= 0);
    records = drain(third);
    CHECK(records.size() == 1 && records[0] == std::make_pair(uint16_t(40), uint64_t(104)));
    CHECK(registrations.size() == 1);
    // A forget of a buffer of the previous session sends nothing.
    CHECK(registrations.forget(Identity{1, 12}));
    CHECK(drain(third).empty());

    for (int fd : {third, second, listener, session, buffer}) close(fd);
    unlink(surface.c_str());
    unlink(device.c_str());
    rmdir(directory);
    if (failures) return 1;
    std::puts("registration: kept across closed connections and missing sockets, dropped with their session");
    return 0;
}
