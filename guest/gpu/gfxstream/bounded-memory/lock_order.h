#pragma once
// The driver's lock hierarchy, and a checker for it (docs/gpu-live.md, Lock order).
//
// A thread holding a lock may take only locks below it:
//
//   encoder (VkEncoder's stream lock)
//     flush shadow (caboose::memory::flushShadow)
//       tracker (ResourceTracker::mLock)
//         deferred replies (caboose::memory::deferredReplies)
//           completion tracker (caboose::completion::tracker())
//             registration (dmabuf registrations)
//
// Taking the same lock again (the tracker's is recursive) or another instance of the same
// lock (two encoders) is allowed. With CABOOSE_LOCK_ORDER=1 every acquisition is checked
// against the hierarchy, and each lock taken above one already held is reported once
// (CABOOSE_LOCK_ORDER took=… holding=…, with the calling frames); with CABOOSE_LOCK_ORDER=abort
// the process also aborts there, for the gates. Unset, a check costs one load.

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <execinfo.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#endif

namespace caboose::lock_order {

enum Class : uint8_t { kEncoder = 1, kFlushShadow, kTracker, kDeferredReplies, kCompletion, kRegistration, kClasses };

inline const char* name(Class c) {
    switch (c) {
        case kEncoder: return "encoder";
        case kFlushShadow: return "flush-shadow";
        case kTracker: return "tracker";
        case kDeferredReplies: return "deferred-replies";
        case kCompletion: return "completion";
        case kRegistration: return "registration";
        default: return "?";
    }
}

// 0: off, 1: report, 2: report and abort.
inline int mode() {
    static const int value = [] {
        const char* v = std::getenv("CABOOSE_LOCK_ORDER");
        if (!v || !*v || std::strcmp(v, "0") == 0) return 0;
        return std::strcmp(v, "abort") == 0 ? 2 : 1;
    }();
    return value;
}

struct Held {
    uint8_t counts[kClasses] = {};
};
inline thread_local Held held;
inline std::atomic<uint64_t> reported{0};  // bit (held * kClasses + taken)

// Whether taking `taken` while holding what this thread holds keeps the hierarchy; the first
// lock held above it, or 0.
inline Class violation(const Held& state, Class taken) {
    for (int c = kClasses - 1; c > taken; --c)
        if (state.counts[c]) return Class(c);
    return Class(0);
}

inline long thread() {
#if defined(__linux__)
    return long(syscall(SYS_gettid));
#else
    return 0;
#endif
}

inline void report(Class held, Class taken) {
    const uint64_t bit = uint64_t(1) << (unsigned(held) * kClasses + unsigned(taken));
    if (reported.fetch_or(bit, std::memory_order_relaxed) & bit) return;
    char line[160];
    const int n = std::snprintf(line, sizeof(line), "CABOOSE_LOCK_ORDER took=%s holding=%s thread=%ld\n",
                                name(taken), name(held), thread());
    if (n > 0) (void)!write(2, line, size_t(n) < sizeof(line) ? size_t(n) : sizeof(line) - 1);
    void* frames[24];
    const int count = backtrace(frames, 24);
    backtrace_symbols_fd(frames, count, 2);
    if (mode() == 2) std::abort();
}

inline void acquired(Class c) {
    if (!mode()) return;
    if (Class over = violation(held, c)) report(over, c);
    if (held.counts[c] < 255) ++held.counts[c];
}

inline void released(Class c) {
    if (!mode()) return;
    if (held.counts[c]) --held.counts[c];
}

// A mutex of class C: the standard mutex `M` whose acquisitions are checked.
template <class M, Class C>
class Mutex {
public:
    void lock() {
        acquired(C);
        inner_.lock();
    }
    // A try never waits, so it cannot deadlock: it is counted, not checked.
    bool try_lock() {
        if (!inner_.try_lock()) return false;
        if (mode() && held.counts[C] < 255) ++held.counts[C];
        return true;
    }
    void unlock() {
        inner_.unlock();
        released(C);
    }

private:
    M inner_;
};

}  // namespace caboose::lock_order
