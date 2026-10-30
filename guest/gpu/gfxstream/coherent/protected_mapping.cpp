// SPDX-License-Identifier: AGPL-3.0-or-later
#include "protected_mapping.h"
#include <cerrno>
#include <cstdlib>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <limits>
#include <stdexcept>
#include <system_error>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace caboose::coherent {
namespace {
void failure(const char* what) { throw std::system_error(errno, std::generic_category(), what); }
}
ProtectedMapping::ProtectedMapping(size_t bytes) {
    const long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || !bytes || bytes > std::numeric_limits<size_t>::max() - size_t(page) + 1)
        throw std::invalid_argument("invalid protected mapping size");
    size_ = (bytes + size_t(page) - 1) / size_t(page) * size_t(page);
    // Require kernel-origin writes to fault too (e.g. read(fd, mapped, n)).
    // USER_MODE_ONLY would SIGBUS those otherwise valid application accesses.
    // Permission denial is unsupported; never silently fall back to that mode.
    fd_ = int(syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK));
    if (fd_ < 0) failure("userfaultfd (kernel faults required)");
    try {
        uffdio_api api{}; api.api = UFFD_API; api.features = UFFD_FEATURE_PAGEFAULT_FLAG_WP;
        if (ioctl(fd_, UFFDIO_API, &api) < 0) failure("UFFDIO_API");
        if (!(api.features & UFFD_FEATURE_PAGEFAULT_FLAG_WP))
            throw std::runtime_error("userfaultfd write protection unavailable");
        data_ = mmap(nullptr, size_, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
        if (data_ == MAP_FAILED) { data_ = nullptr; failure("mmap"); }
        // Populate real writable pages before registration: older kernels do
        // not write-protect missing PTEs. Do not rely on the shared zero page.
        auto* bytesPtr = static_cast<volatile unsigned char*>(data_);
        for (size_t offset = 0; offset < size_; offset += size_t(page)) bytesPtr[offset] = 0;
        uffdio_register registration{};
        registration.range.start = reinterpret_cast<unsigned long>(data_);
        registration.range.len = size_;
        registration.mode = UFFDIO_REGISTER_MODE_WP;
        if (ioctl(fd_, UFFDIO_REGISTER, &registration) < 0) failure("UFFDIO_REGISTER");
        if (!(registration.ioctls & (1ULL << _UFFDIO_WRITEPROTECT)))
            throw std::runtime_error("mapping cannot be write protected");
    } catch (...) {
        if (data_) munmap(data_, size_);
        close(fd_); throw;
    }
}
ProtectedMapping::~ProtectedMapping() {
    // Caller joins mapping users before destruction, as with vkFreeMemory.
    if (data_) munmap(data_, size_);
    if (fd_ >= 0) close(fd_);
}
void ProtectedMapping::protect(bool enabled) {
    if (fd_ < 0) throw std::runtime_error("protected mapping lost");
    uffdio_writeprotect request{};
    request.range.start = reinterpret_cast<unsigned long>(data_);
    request.range.len = size_;
    request.mode = enabled ? UFFDIO_WRITEPROTECT_MODE_WP : 0;
    if (ioctl(fd_, UFFDIO_WRITEPROTECT, &request) < 0) failure("UFFDIO_WRITEPROTECT");
}
bool ProtectedMapping::lost() {
    std::lock_guard<std::mutex> lock(mutex_);
    return fd_ < 0;
}
ProtectedMapping::Frozen::Frozen(ProtectedMapping& mapping)
    : mapping_(mapping), lock_(mapping.mutex_) {
    try { mapping_.protect(true); } catch (...) {
        // Do not leave a potentially partially protected range behind.
        if (mapping_.fd_ >= 0) close(mapping_.fd_);
        mapping_.fd_ = -1;
        throw;
    }
}
ProtectedMapping::Frozen::~Frozen() {
    // Clearing WP wakes all faulted stores without waiting for a GPU or event.
    // Closing the descriptor unregisters ranges and wakes blocked faults. Mark
    // this mapping lost instead of aborting unrelated logical devices.
    try { mapping_.protect(false); } catch (...) {
        close(mapping_.fd_); mapping_.fd_ = -1; return;
    }
    // Drain any already-queued notifications. They carry no ownership evidence;
    // page protection, not delivery of these messages, establishes the cut.
    uffd_msg message{};
    for (;;) {
        const auto n = read(mapping_.fd_, &message, sizeof(message));
        if (n == sizeof(message)) continue;
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) break;
        if (n == 0) break;
        close(mapping_.fd_); mapping_.fd_ = -1; break;
    }
}
}
