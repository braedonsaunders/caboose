// SPDX-License-Identifier: MIT
// Exit 0 pass, 1 failure, 77 without a vgem device.
#include "dmabuf.h"

#include <cstdio>
#include <sys/mman.h>

using namespace caboose::dmabuf;

static int failures = 0;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #c); ++failures; } } while (0)

int main() {
    const int fd = create(1920 * 1080 * 4);
    if (fd < 0 && errno == ENODEV) { std::puts("no vgem device"); return 77; }
    CHECK(fd >= 0);
    if (fd < 0) return 1;
    CHECK(size(fd) >= 1920u * 1080 * 4);
    // Every descriptor of one buffer has its identity; another buffer does not.
    const auto identity = identify(fd);
    CHECK(identity.has_value());
    const int copy = fcntl(fd, F_DUPFD_CLOEXEC, 0);
    CHECK(identify(copy) == identity);
    const int other = create(4096);
    CHECK(identify(other).has_value() && !(*identify(other) == *identity));
    // Ordinary files are not dma-bufs.
    const int null = open("/dev/null", O_RDONLY | O_CLOEXEC);
    CHECK(!identify(null).has_value());
    CHECK(!identify(-1).has_value());
    // A remote buffer's pages are never touched: creating one commits no memory, so a
    // thousand 4K buffers fit easily.
    for (int i = 0; i < 1000; ++i) {
        const int big = create(3840ull * 2160 * 4);
        CHECK(big >= 0);
        close(big);
    }

    SharedAllocations shared;
    CHECK(!shared.acquire(*identity));
    CHECK(shared.insert(*identity, 0x1234, copy, size(fd)));
    CHECK(!shared.insert(*identity, 0x5678, other, 4096));  // One allocation per buffer.
    auto second = shared.acquire(*identity);
    CHECK(second && second->host == 0x1234 && second->users == 2);
    const int exported = shared.duplicate(*identity);
    CHECK(identify(exported) == identity);
    close(exported);
    CHECK(!shared.release(*identity));  // One user remains.
    CHECK(shared.release(*identity));   // The last: the caller frees the host allocation.
    CHECK(!shared.release(*identity));
    CHECK(shared.count() == 0);
    CHECK(fcntl(copy, F_GETFD) == -1 && errno == EBADF);  // Its descriptor was closed.

    close(fd);
    close(other);
    close(null);
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("dmabuf_test: pass");
    return 0;
}
