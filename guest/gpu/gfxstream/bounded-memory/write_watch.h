// SPDX-License-Identifier: MIT
#pragma once

// Which parts of host-coherent memory an application wrote since they were last sent. Before
// every submit the socket path must send what the application wrote to its coherent mappings;
// without a record of writes it sends every mapping, compared against a copy where one fits
// the shadow's budget and whole where it does not (a D3D11 game's 64 MiB chunks: over 100 MB
// a frame). The guest's copy of each coherent allocation is write-protected with userfaultfd,
// which reports the first write to each block to a thread of the watch's own and lets it
// proceed; the flush takes the written blocks and protects them again before reading them.
// No signal is involved, so it coexists with Wine's handlers. Where userfaultfd is not
// available the flush sends every mapping as before.

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <thread>
#include <vector>

#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

namespace caboose::memory {

// Writes are recorded per block: one fault each, and a flush sends whole written blocks.
inline constexpr uint64_t watchBlockBytes = 16 * 1024;

// The written blocks of one watched allocation, as a bitmap. Pure bookkeeping, separate from
// the kernel interface so it can be tested anywhere.
class WrittenBlocks {
public:
    explicit WrittenBlocks(uint64_t bytes) : bytes_(bytes), bits_((blocks(bytes) + 63) / 64, 0) {}

    void mark(uint64_t offset) {
        if (offset >= bytes_) return;
        const uint64_t block = offset / watchBlockBytes;
        bits_[size_t(block / 64)] |= uint64_t(1) << (block % 64);
        any_ = true;
    }
    bool any() const { return any_; }
    // Calls take(begin, end) for each run of written blocks inside [from, to), clearing them;
    // runs are clipped to [from, to) and to the allocation.
    template <class Take>
    void take(uint64_t from, uint64_t to, Take&& take) {
        if (!any_) return;
        to = std::min(to, bytes_);
        if (from >= to) return;
        const uint64_t first = from / watchBlockBytes, last = (to - 1) / watchBlockBytes;
        uint64_t runStart = 0;
        bool inRun = false;
        for (uint64_t block = first; block <= last; ++block) {
            uint64_t& word = bits_[size_t(block / 64)];
            const uint64_t bit = uint64_t(1) << (block % 64);
            const bool written = word & bit;
            if (written) {
                word &= ~bit;
                if (!inRun) { runStart = block; inRun = true; }
            } else if (inRun) {
                take(std::max(from, runStart * watchBlockBytes), std::min(to, block * watchBlockBytes));
                inRun = false;
            }
        }
        if (inRun) take(std::max(from, runStart * watchBlockBytes), to);
        any_ = std::any_of(bits_.begin(), bits_.end(), [](uint64_t word) { return word != 0; });
    }

private:
    static uint64_t blocks(uint64_t bytes) { return (bytes + watchBlockBytes - 1) / watchBlockBytes; }
    uint64_t bytes_;
    std::vector<uint64_t> bits_;
    bool any_ = false;
};

class WriteWatch {
public:
    // Whether writes to watched memory are recorded in this process.
    bool available() {
        std::call_once(opened_, [this] { open(); });
        return fd_ >= 0;
    }

    // Starts recording writes to [base, base + bytes), page-aligned memory this process
    // mapped privately and anonymously. Nothing in it counts as written yet.
    bool watch(uint8_t* base, uint64_t bytes) {
        if (!available() || !bytes || reinterpret_cast<uintptr_t>(base) % pageBytes() || bytes % pageBytes()) return false;
        uffdio_register reg{};
        reg.range = {reinterpret_cast<uintptr_t>(base), bytes};
        reg.mode = UFFDIO_REGISTER_MODE_WP;
        if (ioctl(fd_, UFFDIO_REGISTER, &reg) != 0) return false;
        std::lock_guard<std::mutex> lock(mutex_);
        if (!protect(reinterpret_cast<uintptr_t>(base), bytes, true)) {
            uffdio_range range{reinterpret_cast<uintptr_t>(base), bytes};
            ioctl(fd_, UFFDIO_UNREGISTER, &range);
            return false;
        }
        regions_.insert_or_assign(reinterpret_cast<uintptr_t>(base), Region{bytes, WrittenBlocks(bytes)});
        return true;
    }
    // Stops recording writes to the watched memory at `base`, before it is unmapped.
    void unwatch(uint8_t* base) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
        if (found == regions_.end()) return;
        uffdio_range range{found->first, found->second.bytes};
        ioctl(fd_, UFFDIO_UNREGISTER, &range);
        regions_.erase(found);
    }
    bool watched(const uint8_t* base) {
        std::lock_guard<std::mutex> lock(mutex_);
        return regions_.count(reinterpret_cast<uintptr_t>(base)) != 0;
    }
    // Calls take(begin, end), offsets from `base`, for each run of blocks written in
    // [from, to) of the watched memory at `base`, and protects them again first: a write
    // made while they are being sent is recorded for the next flush. False when the memory
    // is not watched (all of it must be sent).
    template <class Take>
    bool written(const uint8_t* base, uint64_t from, uint64_t to, Take&& take) {
        std::vector<std::pair<uint64_t, uint64_t>> runs;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = regions_.find(reinterpret_cast<uintptr_t>(base));
            if (found == regions_.end()) return false;
            found->second.blocks.take(from, to, [&](uint64_t begin, uint64_t end) { runs.emplace_back(begin, end); });
            for (const auto& [begin, end] : runs) {
                const uintptr_t first = (found->first + begin) / pageBytes() * pageBytes();
                const uintptr_t last = (found->first + end + pageBytes() - 1) / pageBytes() * pageBytes();
                if (!protect(first, last - first, true)) {
                    // Unprotected memory records nothing: stop watching it, and send it whole.
                    uffdio_range range{found->first, found->second.bytes};
                    ioctl(fd_, UFFDIO_UNREGISTER, &range);
                    regions_.erase(found);
                    return false;
                }
            }
        }
        for (const auto& [begin, end] : runs) take(begin, end);
        return true;
    }
    uint64_t faults() const { return faults_.load(std::memory_order_relaxed); }

private:
    struct Region {
        uint64_t bytes;
        WrittenBlocks blocks;
    };

    static uint64_t pageBytes() {
        static const uint64_t bytes = uint64_t(sysconf(_SC_PAGESIZE));
        return bytes;
    }

    void open() {
        // Only through the device: its descriptors also take the kernel's own writes (a
        // read() into a mapping), which a user-mode-only descriptor from the system call
        // would fail with EFAULT.
        const int device = ::open("/dev/userfaultfd", O_RDWR | O_CLOEXEC);
        if (device < 0) return;
        const int fd = ioctl(device, USERFAULTFD_IOC_NEW, O_CLOEXEC | O_NONBLOCK);
        ::close(device);
        if (fd < 0) return;
        // Unpopulated pages must be protected too: a fresh allocation is all unpopulated.
        uffdio_api api{};
        api.api = UFFD_API;
        api.features = UFFD_FEATURE_WP_UNPOPULATED;
        if (ioctl(fd, UFFDIO_API, &api) != 0 || !(api.features & UFFD_FEATURE_WP_UNPOPULATED)) {
            ::close(fd);
            return;
        }
        try {
            std::thread([this, fd] { serve(fd); }).detach();
        } catch (...) {
            ::close(fd);
            return;
        }
        fd_ = fd;
    }

    bool protect(uintptr_t start, uint64_t bytes, bool on) {
        uffdio_writeprotect wp{};
        wp.range = {start, bytes};
        wp.mode = on ? UFFDIO_WRITEPROTECT_MODE_WP : 0;
        while (ioctl(fd_, UFFDIO_WRITEPROTECT, &wp) != 0) {
            if (errno != EAGAIN && errno != EINTR) return false;
        }
        return true;
    }

    // Records each first write to a protected block and lets the writer go on.
    void serve(int fd) {
        for (;;) {
            pollfd ready{fd, POLLIN, 0};
            if (poll(&ready, 1, -1) < 0 && errno != EINTR) return;
            uffd_msg message;
            const ssize_t got = read(fd, &message, sizeof(message));
            if (got != ssize_t(sizeof(message))) continue;
            if (message.event != UFFD_EVENT_PAGEFAULT || !(message.arg.pagefault.flags & UFFD_PAGEFAULT_FLAG_WP)) continue;
            const uintptr_t address = uintptr_t(message.arg.pagefault.address);
            faults_.fetch_add(1, std::memory_order_relaxed);
            std::lock_guard<std::mutex> lock(mutex_);
            auto found = regions_.upper_bound(address);
            if (found != regions_.begin()) {
                --found;
                if (address < found->first + found->second.bytes) {
                    const uint64_t offset = address - found->first;
                    const uint64_t block = offset / watchBlockBytes * watchBlockBytes;
                    const uint64_t end = std::min(found->second.bytes, block + watchBlockBytes);
                    found->second.blocks.mark(offset);
                    // The whole block goes unprotected: one fault per block, not per page.
                    if (protect(found->first + block, end - block, false)) continue;
                }
            }
            // Not memory this watch protects (anymore): let the writer go on regardless.
            const uintptr_t page = address / pageBytes() * pageBytes();
            protect(page, pageBytes(), false);
        }
    }

    std::once_flag opened_;
    int fd_ = -1;
    std::mutex mutex_;
    std::map<uintptr_t, Region> regions_;
    std::atomic<uint64_t> faults_{0};
};

inline WriteWatch& writeWatch() {
    static WriteWatch* instance = new WriteWatch;  // its thread outlives static destruction
    return *instance;
}

}  // namespace caboose::memory
