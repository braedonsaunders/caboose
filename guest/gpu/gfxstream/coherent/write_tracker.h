// SPDX-License-Identifier: MIT
//
// Kernel-assisted write tracking for guest-mapped Vulkan memory.
//
// A TrackedRegion is an anonymous private mapping registered for userfaultfd
// write protection. The first store to a protected chunk faults to one
// process-wide handler thread, which records the chunk's pages as written and
// removes protection from that chunk, so later stores run at full speed.
// consume() re-arms protection on the written pages of an interval before it
// reports them, so every store is either reported by that call or faults again
// and is reported by a later one. The cost of a flush therefore scales with the
// bytes written since the previous one, not with the bytes mapped.
//
// Invariant, held under the region mutex: a page that is writable is marked
// written. The handler marks before it unprotects; consume() protects before it
// clears a mark.
//
// The descriptor is created with kernel-fault handling (never
// UFFD_USER_MODE_ONLY), so read(fd, mappedPointer, n) and other kernel-origin
// stores are tracked rather than failing with EFAULT. It is obtained from
// /dev/userfaultfd, or the userfaultfd syscall when the process may use it.
// When neither is available, allocate() returns null and the caller keeps its
// untracked path.
#pragma once

#if defined(__linux__)

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <map>
#include <poll.h>
#include <memory>
#include <mutex>
#include <new>
#include <shared_mutex>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <thread>
#include <unistd.h>
#include <vector>

#ifndef USERFAULTFD_IOC_NEW
#define USERFAULTFD_IOC_NEW _IO(0xAA, 0x00)
#endif
#ifndef UFFD_FEATURE_WP_UNPOPULATED
#define UFFD_FEATURE_WP_UNPOPULATED (1 << 13)
#endif

namespace caboose::coherent {

// A fault unprotects a whole extent rather than one page. The extent starts at
// 64 KiB and doubles, up to 4 MiB, while faults continue exactly where the
// previous extent ended, so a sequential writer takes a logarithmic number of
// faults and a sparse writer keeps fine granularity. consume() reports page runs.
// A caller that cannot compare reported bytes against a previous copy, and so
// must transmit every reported byte, passes a smaller maximum extent.
// One fault costs about as much as comparing a few hundred KiB, so callers
// should track only allocations that are large relative to what is written.
inline constexpr uint64_t trackerPageBytes = 4096;
inline constexpr uint64_t trackerChunkPages = 16;
inline constexpr uint64_t trackerMaxExtentPages = 1024;
// After serving a fault the handler polls for this long before sleeping:
// waking a sleeping thread dominates the cost of a fault burst under a
// hypervisor (measured on WSL2: 63 us per sparse fault sleeping, 30 us polling).
inline constexpr auto trackerHandlerPoll = std::chrono::microseconds(200);

struct TrackerStats {
    uint64_t faults = 0;          // write faults resolved by the handler
    uint64_t faultNanos = 0;      // handler time from message receipt to wake
    uint64_t faultMaxNanos = 0;
    uint64_t consumedBytes = 0;   // page bytes reported written by consume()
    uint64_t regions = 0;         // live tracked regions
};

class TrackedRegion;

class WriteTracker {
public:
    // The process-wide tracker, or null when write protection is unavailable.
    // Deliberately leaked: its handler thread may serve faults during static
    // destruction of other objects.
    static WriteTracker* get() {
        static WriteTracker* instance = create();
        // The descriptor operates on its creator's address space: a forked
        // child must not register its own mappings through it.
        return instance && instance->owner_ == getpid() ? instance : nullptr;
    }

    // Why get() returned null: 0 when available, otherwise an errno, or
    // ENOTSUP when the kernel lacks write protection, or ECANCELED when
    // disabled with CABOOSE_COHERENT_WRITE_TRACKING=off.
    static int unavailableReason() {
        get();
        return reason().load(std::memory_order_relaxed);
    }

    bool unpopulatedProtection() const { return unpopulated_; }

    TrackerStats stats() const {
        TrackerStats s;
        s.faults = faults_.load(std::memory_order_relaxed);
        s.faultNanos = faultNanos_.load(std::memory_order_relaxed);
        s.faultMaxNanos = faultMaxNanos_.load(std::memory_order_relaxed);
        s.consumedBytes = consumedBytes_.load(std::memory_order_relaxed);
        s.regions = regions_.load(std::memory_order_relaxed);
        return s;
    }

    // A zero-filled tracked mapping of at least `bytes`, initially protected,
    // or null. maxExtentPages bounds what one fault releases (and reports).
    inline std::shared_ptr<TrackedRegion> allocate(uint64_t bytes,
                                                   uint64_t maxExtentPages = trackerMaxExtentPages);

private:
    friend class TrackedRegion;

    static std::atomic<int>& reason() {
        static std::atomic<int> value{0};
        return value;
    }

    static int openDescriptor() {
        const int device = open("/dev/userfaultfd", O_RDWR | O_CLOEXEC);
        if (device >= 0) {
            const int fd = ioctl(device, USERFAULTFD_IOC_NEW, O_CLOEXEC | O_NONBLOCK);
            const int saved = errno;
            close(device);
            if (fd >= 0) return fd;
            errno = saved;
        }
        const int deviceErrno = errno;
        const int fd = int(syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK));
        if (fd >= 0) return fd;
        // Report the device's error when the syscall is merely filtered.
        if (errno == EPERM || errno == ENOSYS) errno = deviceErrno;
        return -1;
    }

    static WriteTracker* create() {
        const char* mode = std::getenv("CABOOSE_COHERENT_WRITE_TRACKING");
        if (mode && std::strcmp(mode, "off") == 0) {
            reason().store(ECANCELED, std::memory_order_relaxed);
            return nullptr;
        }
        // UFFDIO_API may be issued once per descriptor: probe on a throwaway one.
        uint64_t supported = 0;
        {
            const int probe = openDescriptor();
            if (probe < 0) { reason().store(errno ? errno : EPERM, std::memory_order_relaxed); return nullptr; }
            uffdio_api api{};
            api.api = UFFD_API;
            const bool ok = ioctl(probe, UFFDIO_API, &api) == 0;
            const int saved = errno;
            close(probe);
            if (!ok) { reason().store(saved, std::memory_order_relaxed); return nullptr; }
            supported = api.features;
        }
        if (!(supported & UFFD_FEATURE_PAGEFAULT_FLAG_WP)) {
            reason().store(ENOTSUP, std::memory_order_relaxed);
            return nullptr;
        }
        const int fd = openDescriptor();
        if (fd < 0) { reason().store(errno ? errno : EPERM, std::memory_order_relaxed); return nullptr; }
        uffdio_api api{};
        api.api = UFFD_API;
        api.features = UFFD_FEATURE_PAGEFAULT_FLAG_WP | (supported & UFFD_FEATURE_WP_UNPOPULATED);
        if (ioctl(fd, UFFDIO_API, &api) != 0) {
            reason().store(errno, std::memory_order_relaxed);
            close(fd);
            return nullptr;
        }
        auto* tracker = new (std::nothrow) WriteTracker(fd, (api.features & UFFD_FEATURE_WP_UNPOPULATED) != 0);
        if (!tracker) { close(fd); reason().store(ENOMEM, std::memory_order_relaxed); return nullptr; }
        try {
            std::thread([tracker] { tracker->serve(); }).detach();
        } catch (...) {
            // Never used: no region can have been registered yet.
            reason().store(EAGAIN, std::memory_order_relaxed);
            return nullptr;
        }
        return tracker;
    }

    WriteTracker(int fd, bool unpopulated) : fd_(fd), unpopulated_(unpopulated), owner_(getpid()) {}

    inline void serve();
    inline void resolve(uint64_t address);

    int writeProtect(uint64_t start, uint64_t length, bool enable) const {
        uffdio_writeprotect request{};
        request.range.start = start;
        request.range.len = length;
        request.mode = enable ? UFFDIO_WRITEPROTECT_MODE_WP : 0;
        while (ioctl(fd_, UFFDIO_WRITEPROTECT, &request) != 0) {
            if (errno != EINTR && errno != EAGAIN) return errno;
        }
        return 0;
    }

    void wake(uint64_t address) const {
        uffdio_range range{};
        range.start = address & ~(trackerPageBytes - 1);
        range.len = trackerPageBytes;
        ioctl(fd_, UFFDIO_WAKE, &range);
    }

    const int fd_;
    const bool unpopulated_;
    const pid_t owner_;
    std::shared_mutex registryMutex_;
    std::map<uint64_t, TrackedRegion*> registry_;  // keyed by mapping end
    std::atomic<uint64_t> faults_{0}, faultNanos_{0}, faultMaxNanos_{0}, consumedBytes_{0}, regions_{0};
};

class TrackedRegion {
public:
    TrackedRegion(const TrackedRegion&) = delete;
    TrackedRegion& operator=(const TrackedRegion&) = delete;

    ~TrackedRegion() {
        if (tracker_.owner_ != getpid()) {  // A forked child's copy of the mapping.
            munmap(data_, mapped_);
            return;
        }
        {
            std::unique_lock<std::shared_mutex> registry(tracker_.registryMutex_);
            tracker_.registry_.erase(begin() + mapped_);
        }
        uffdio_range range{};
        range.start = begin();
        range.len = mapped_;
        ioctl(tracker_.fd_, UFFDIO_UNREGISTER, &range);
        munmap(data_, mapped_);
        tracker_.regions_.fetch_sub(1, std::memory_order_relaxed);
    }

    uint8_t* data() const { return data_; }
    uint64_t size() const { return size_; }

    // Whether any page is marked written. A racing store may be missed; it is
    // then reported by a later consume().
    bool written() const { return writtenPages_.load(std::memory_order_acquire) != 0; }

    // Reports the pages written inside [offset, offset + size) since they were
    // last consumed, as maximal runs clipped to that interval, and re-arms
    // protection on them first. A page only partly inside the interval is
    // reported and stays marked. Stops at, and returns, the first nonzero
    // result of visit(runOffset, runSize). Returns an errno, after which
    // nothing has been unmarked, if protection cannot be re-armed.
    template<class Visit>
    int consume(uint64_t offset, uint64_t size, Visit visit) {
        if (offset >= size_ || !size) return 0;
        const uint64_t end = size > size_ - offset ? size_ : offset + size;
        struct Run { uint64_t begin, end; };
        std::vector<Run> runs;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const uint64_t firstPage = offset / trackerPageBytes;
            const uint64_t lastPage = (end - 1) / trackerPageBytes;
            uint64_t page = firstPage;
            while (page <= lastPage) {
                if (!marked(page)) { ++page; continue; }
                uint64_t stop = page + 1;
                while (stop <= lastPage && marked(stop)) ++stop;
                const int error = tracker_.writeProtect(begin() + page * trackerPageBytes,
                                                        (stop - page) * trackerPageBytes, true);
                if (error) return error;
                const uint64_t runBegin = page * trackerPageBytes < offset ? offset : page * trackerPageBytes;
                const uint64_t runEnd = stop * trackerPageBytes > end ? end : stop * trackerPageBytes;
                runs.push_back(Run{runBegin, runEnd});
                for (uint64_t p = page; p < stop; ++p) {
                    const uint64_t pageBegin = p * trackerPageBytes;
                    const uint64_t pageEnd = pageBegin + trackerPageBytes < size_ ? pageBegin + trackerPageBytes : size_;
                    if (pageBegin >= offset && pageEnd <= end) unmark(p);
                }
                page = stop;
            }
        }
        for (const Run& run : runs) {
            tracker_.consumedBytes_.fetch_add(run.end - run.begin, std::memory_order_relaxed);
            const int result = visit(run.begin, run.end - run.begin);
            if (result != 0) return result;
        }
        return 0;
    }

private:
    friend class WriteTracker;

    TrackedRegion(WriteTracker& tracker, uint8_t* data, uint64_t size, uint64_t mapped, uint64_t maxExtentPages)
        : tracker_(tracker), data_(data), size_(size), mapped_(mapped),
          maxExtentPages_(maxExtentPages < trackerChunkPages ? trackerChunkPages : maxExtentPages),
          bits_((mapped / trackerPageBytes + 63) / 64, 0) {}

    uint64_t begin() const { return uint64_t(reinterpret_cast<uintptr_t>(data_)); }
    bool marked(uint64_t page) const { return (bits_[page / 64] >> (page % 64)) & 1; }
    void mark(uint64_t page) {
        uint64_t& word = bits_[page / 64];
        const uint64_t bit = uint64_t(1) << (page % 64);
        if (!(word & bit)) { word |= bit; writtenPages_.fetch_add(1, std::memory_order_release); }
    }
    void unmark(uint64_t page) {
        uint64_t& word = bits_[page / 64];
        const uint64_t bit = uint64_t(1) << (page % 64);
        if (word & bit) { word &= ~bit; writtenPages_.fetch_sub(1, std::memory_order_release); }
    }

    // Handler side: mark the faulting extent, then make it writable (waking
    // the faulting thread).
    void resolve(uint64_t address) {
        std::lock_guard<std::mutex> lock(mutex_);
        const uint64_t page = (address - begin()) / trackerPageBytes;
        const uint64_t pages = mapped_ / trackerPageBytes;
        const uint64_t first = page - page % trackerChunkPages;
        uint64_t extent = trackerChunkPages;
        if (first == nextExtentPage_)
            extent = lastExtentPages_ * 2 < maxExtentPages_ ? lastExtentPages_ * 2 : maxExtentPages_;
        const uint64_t stop = extent < pages - first ? first + extent : pages;
        lastExtentPages_ = extent;
        nextExtentPage_ = stop;
        for (uint64_t p = first; p < stop; ++p) mark(p);
        if (tracker_.writeProtect(begin() + first * trackerPageBytes, (stop - first) * trackerPageBytes, false))
            tracker_.wake(address);  // Unreachable on a live registration; never strand the writer.
    }

    WriteTracker& tracker_;
    uint8_t* const data_;
    const uint64_t size_;
    const uint64_t mapped_;
    const uint64_t maxExtentPages_;
    std::mutex mutex_;
    std::vector<uint64_t> bits_;
    uint64_t nextExtentPage_ = UINT64_MAX, lastExtentPages_ = 0;
    std::atomic<uint64_t> writtenPages_{0};
};

std::shared_ptr<TrackedRegion> WriteTracker::allocate(uint64_t bytes, uint64_t maxExtentPages) {
    if (!bytes || bytes > (UINT64_MAX - trackerPageBytes) || bytes > SIZE_MAX - trackerPageBytes) return nullptr;
    const uint64_t mapped = (bytes + trackerPageBytes - 1) / trackerPageBytes * trackerPageBytes;
    // Without protection of unpopulated PTEs, pages must exist before they can
    // be protected, so populate them at the cost of committing the memory.
    const int flags = MAP_PRIVATE | MAP_ANONYMOUS | (unpopulated_ ? 0 : MAP_POPULATE);
    void* data = mmap(nullptr, size_t(mapped), PROT_READ | PROT_WRITE, flags, -1, 0);
    if (data == MAP_FAILED) return nullptr;
    // Keep 4 KiB granularity: a write-protected huge page splits on first store.
    madvise(data, size_t(mapped), MADV_NOHUGEPAGE);
    // MAP_POPULATE may map the shared zero page read-only; force real pages.
    if (!unpopulated_) {
        auto* bytesPtr = static_cast<volatile uint8_t*>(data);
        for (uint64_t offset = 0; offset < mapped; offset += trackerPageBytes) bytesPtr[offset] = 0;
    }
    uffdio_register registration{};
    registration.range.start = uint64_t(reinterpret_cast<uintptr_t>(data));
    registration.range.len = mapped;
    registration.mode = UFFDIO_REGISTER_MODE_WP;
    if (ioctl(fd_, UFFDIO_REGISTER, &registration) != 0 ||
        !(registration.ioctls & (uint64_t(1) << _UFFDIO_WRITEPROTECT))) {
        munmap(data, size_t(mapped));
        return nullptr;
    }
    std::shared_ptr<TrackedRegion> region;
    try {
        region.reset(new TrackedRegion(*this, static_cast<uint8_t*>(data), bytes, mapped, maxExtentPages));
    } catch (...) {
        uffdio_range range{registration.range.start, mapped};
        ioctl(fd_, UFFDIO_UNREGISTER, &range);
        munmap(data, size_t(mapped));
        return nullptr;
    }
    regions_.fetch_add(1, std::memory_order_relaxed);
    // From here the destructor owns unregistration.
    if (writeProtect(registration.range.start, mapped, true) != 0) return nullptr;
    try {
        std::unique_lock<std::shared_mutex> registry(registryMutex_);
        registry_.emplace(registration.range.start + mapped, region.get());
    } catch (...) {
        return nullptr;
    }
    return region;
}

void WriteTracker::resolve(uint64_t address) {
    std::shared_lock<std::shared_mutex> registry(registryMutex_);
    auto found = registry_.upper_bound(address);
    if (found == registry_.end() || address < found->second->begin()) {
        // A region being destroyed: its registration is going away with it.
        wake(address);
        return;
    }
    found->second->resolve(address);
}

void WriteTracker::serve() {
    uffd_msg messages[16];
    auto pollUntil = std::chrono::steady_clock::time_point{};
    for (;;) {
        const ssize_t n = read(fd_, messages, sizeof(messages));
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN) return;  // The descriptor is never closed.
            if (std::chrono::steady_clock::now() < pollUntil) continue;
            pollfd ready{fd_, POLLIN, 0};
            poll(&ready, 1, -1);
            continue;
        }
        const auto received = std::chrono::steady_clock::now();
        for (size_t i = 0; i < size_t(n) / sizeof(uffd_msg); ++i) {
            if (messages[i].event != UFFD_EVENT_PAGEFAULT) continue;
            resolve(messages[i].arg.pagefault.address);
        }
        const uint64_t nanos = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - received).count());
        faults_.fetch_add(uint64_t(n) / sizeof(uffd_msg), std::memory_order_relaxed);
        faultNanos_.fetch_add(nanos, std::memory_order_relaxed);
        uint64_t prior = faultMaxNanos_.load(std::memory_order_relaxed);
        while (nanos > prior && !faultMaxNanos_.compare_exchange_weak(prior, nanos, std::memory_order_relaxed)) {}
        pollUntil = std::chrono::steady_clock::now() + trackerHandlerPoll;
    }
}

}  // namespace caboose::coherent

#endif  // __linux__
