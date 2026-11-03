// SPDX-License-Identifier: MIT
//
// Registrations against a stand-in broker socket: the first registration connects, a
// connection the broker closed is replaced by the next registration (which still arrives),
// and a missing socket is tried again after its retry interval.
#include "registration.h"

#include <cstdio>
#include <cstdlib>
#include <string>
#include <sys/mman.h>
#include <thread>

using caboose::dmabuf::RegisteredImage;
using caboose::dmabuf::Registrations;

static int failures = 0;
#define CHECK(condition)                                                     \
    do {                                                                     \
        if (!(condition)) {                                                  \
            std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #condition); \
            ++failures;                                                      \
        }                                                                    \
    } while (0)

static int listenAt(const std::string& path) {
    const int fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    std::strcpy(address.sun_path, path.c_str());
    unlink(path.c_str());
    if (fd < 0 || bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(fd, 4)) return -1;
    return fd;
}

// One record from an accepted connection: its kind, and whether it carried a descriptor.
static bool receive(int connection, uint16_t* kind, bool* descriptor) {
    uint8_t data[256];
    iovec io{data, sizeof(data)};
    alignas(cmsghdr) char control[CMSG_SPACE(sizeof(int))] = {};
    msghdr message{};
    message.msg_iov = &io;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = sizeof(control);
    const ssize_t got = recvmsg(connection, &message, 0);
    if (got < 16 || std::memcmp(data, "CGLS", 4)) return false;
    *kind = uint16_t(data[6] | data[7] << 8);
    cmsghdr* header = CMSG_FIRSTHDR(&message);
    *descriptor = header && header->cmsg_type == SCM_RIGHTS;
    if (*descriptor) {
        int fd;
        std::memcpy(&fd, CMSG_DATA(header), sizeof(fd));
        close(fd);
    }
    return true;
}

int main() {
    char directory[] = "/tmp/caboose-registration-XXXXXX";
    if (!mkdtemp(directory)) return 1;
    const std::string path = std::string(directory) + "/surface.sock";
    setenv("CABOOSE_GFXSTREAM_SURFACE_SOCKET", path.c_str(), 1);
    const int buffer = memfd_create("buffer", MFD_CLOEXEC);
    const RegisteredImage image{1, 2, 3, 4, 44, 640, 480, 0};
    uint16_t kind = 0;
    bool descriptor = false;

    // No broker yet: nothing is registered, and the socket is not tried again at once.
    Registrations registrations;
    CHECK(!registrations.add(buffer, image));
    const int listener = listenAt(path);
    CHECK(listener >= 0);
    CHECK(!registrations.add(buffer, image));
    std::this_thread::sleep_for(std::chrono::milliseconds(1100));

    // After the retry interval the registration connects and arrives with its dma-buf.
    CHECK(registrations.add(buffer, image));
    int first = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
    CHECK(first >= 0);
    CHECK(receive(first, &kind, &descriptor) && kind == 40 && descriptor);
    CHECK(registrations.forget({7, 8}));
    CHECK(receive(first, &kind, &descriptor) && kind == 41 && !descriptor);

    // The broker closes the connection (the process's executor was lost): the next
    // registration goes out on a new connection.
    close(first);
    CHECK(registrations.add(buffer, image));
    const int second = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
    CHECK(second >= 0);
    CHECK(receive(second, &kind, &descriptor) && kind == 40 && descriptor);

    // A forget after the broker closed the connection is not resent: it was forgotten.
    close(second);
    CHECK(!registrations.forget({7, 8}));
    CHECK(registrations.add(buffer, image));
    const int third = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
    CHECK(third >= 0);
    CHECK(receive(third, &kind, &descriptor) && kind == 40);

    close(third);
    close(listener);
    close(buffer);
    unlink(path.c_str());
    rmdir(directory);
    if (failures) return 1;
    std::puts("registration: reconnects after a closed connection and retries a missing socket");
    return 0;
}
