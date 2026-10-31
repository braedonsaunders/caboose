// SPDX-License-Identifier: MIT
//
// Phone-resident dma-bufs for the Caboose Vulkan driver (docs/gpu-buffers.md).
//
// A remote dma-buf is a vgem object that names phone GPU memory; its inode is its
// identity in every process. Within one process, Vulkan memory imported from or exported
// as the same dma-buf is one host allocation: the first import or export allocates it,
// later imports alias it, and it is freed with the last guest memory object that uses it.
#pragma once

#if defined(__linux__)

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <optional>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

#include <drm/drm.h>
#include <drm/drm_mode.h>

namespace caboose::dmabuf {

struct Identity {
    uint64_t device = 0, inode = 0;
    bool operator<(const Identity& other) const {
        return device != other.device ? device < other.device : inode < other.inode;
    }
    bool operator==(const Identity& other) const { return device == other.device && inode == other.inode; }
};

// The identity of the buffer behind a descriptor, if it is a dma-buf.
inline std::optional<Identity> identify(int fd) {
    constexpr long dmaBufMagic = 0x444d4142;  // DMA_BUF_MAGIC, "DMAB"
    struct statfs fs;
    struct stat st;
    if (fd < 0 || fstatfs(fd, &fs) != 0 || long(fs.f_type) != dmaBufMagic || fstat(fd, &st) != 0)
        return std::nullopt;
    return Identity{uint64_t(st.st_dev), uint64_t(st.st_ino)};
}

inline uint64_t size(int fd) {
    const off_t end = lseek(fd, 0, SEEK_END);
    return end > 0 ? uint64_t(end) : 0;
}

namespace detail {
inline int ioctlRetry(int fd, unsigned long request, void* arg) {
    int ret;
    do ret = ioctl(fd, request, arg);
    while (ret == -1 && (errno == EINTR || errno == EAGAIN));
    return ret;
}

// vgem's primary node: it creates objects only there.
inline int vgemCard() {
    static std::mutex mutex;
    static int card = -1;
    std::lock_guard<std::mutex> lock(mutex);
    if (card >= 0) return card;
    for (int minor = 0; minor < 64; ++minor) {
        char path[32];
        std::snprintf(path, sizeof(path), "/dev/dri/card%d", minor);
        const int fd = open(path, O_RDWR | O_CLOEXEC);
        if (fd < 0) continue;
        char name[16] = {};
        drm_version version{};
        version.name = name;
        version.name_len = sizeof(name) - 1;
        if (ioctlRetry(fd, DRM_IOCTL_VERSION, &version) == 0 && std::strcmp(name, "vgem") == 0) {
            card = fd;
            return card;
        }
        close(fd);
    }
    return -1;
}
}  // namespace detail

// A new remote dma-buf of at least `bytes` (a vgem object whose pages are never touched),
// or -1 with errno set.
inline int create(uint64_t bytes) {
    const int card = detail::vgemCard();
    if (card < 0) {
        errno = ENODEV;
        return -1;
    }
    const uint64_t rows = (bytes + 4095) / 4096;
    if (!bytes || rows > UINT32_MAX) {
        errno = EINVAL;
        return -1;
    }
    drm_mode_create_dumb create{};
    create.width = 4096;
    create.height = uint32_t(rows);
    create.bpp = 8;
    if (detail::ioctlRetry(card, DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) return -1;
    drm_prime_handle prime{};
    prime.handle = create.handle;
    prime.flags = DRM_CLOEXEC | DRM_RDWR;
    const int exported = detail::ioctlRetry(card, DRM_IOCTL_PRIME_HANDLE_TO_FD, &prime);
    const int saved = errno;
    drm_gem_close close{};
    close.handle = create.handle;
    detail::ioctlRetry(card, DRM_IOCTL_GEM_CLOSE, &close);  // The dma-buf keeps it alive.
    if (exported != 0) {
        errno = saved;
        return -1;
    }
    return prime.fd;
}

// Host allocations shared through dma-bufs in this process. Keys are dma-buf identities;
// each entry holds one descriptor of the buffer, so it stays alive and exportable while
// any guest memory object uses it.
class SharedAllocations {
public:
    struct Entry {
        uint64_t host = 0;   // the host allocation's handle
        int fd = -1;         // owned descriptor of the dma-buf
        uint64_t size = 0;   // the host allocation's size
        uint32_t users = 0;  // guest memory objects using it
    };

    // A user of an existing allocation for the buffer, if there is one.
    std::optional<Entry> acquire(const Identity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(identity);
        if (found == entries_.end()) return std::nullopt;
        ++found->second.users;
        return found->second;
    }

    // Records a new allocation with its first user, taking ownership of `fd`. Fails
    // (returning false, `fd` still the caller's) if the buffer already has one.
    bool insert(const Identity& identity, uint64_t host, int fd, uint64_t size) {
        std::lock_guard<std::mutex> lock(mutex_);
        return entries_.emplace(identity, Entry{host, fd, size, 1}).second;
    }

    // Releases one user. Returns true when it was the last: the caller frees the host
    // allocation. The descriptor is closed then.
    bool release(const Identity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(identity);
        if (found == entries_.end() || found->second.users == 0) return false;
        if (--found->second.users) return false;
        if (found->second.fd >= 0) ::close(found->second.fd);
        entries_.erase(found);
        return true;
    }

    // A new descriptor of the buffer, for vkGetMemoryFdKHR, or -1.
    int duplicate(const Identity& identity) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = entries_.find(identity);
        return found == entries_.end() ? -1 : fcntl(found->second.fd, F_DUPFD_CLOEXEC, 0);
    }

    size_t count() {
        std::lock_guard<std::mutex> lock(mutex_);
        return entries_.size();
    }

private:
    std::mutex mutex_;
    std::map<Identity, Entry> entries_;
};

inline SharedAllocations& sharedAllocations() {
    static SharedAllocations* instance = new SharedAllocations();  // Outlives static destructors.
    return *instance;
}

}  // namespace caboose::dmabuf

#endif  // __linux__
