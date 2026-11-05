#pragma once
// CABOOSE_GFXSTREAM_FEATURES_MASK=0x...: hello feature bits this process never offers, for
// diagnosis. Dropping a bit also drops every bit that requires it (gpu-features.json).

#include <cstdint>
#include <cstdio>
#include <cstdlib>

namespace caboose::features {

struct Requirement { uint32_t bit, needs; };
inline constexpr Requirement kRequirements[] = {
    {0x100, 0x80},                 // guest-handle-arrays: guest-handles
    {0x1000, 0x80},                // guest-query-pools
    {0x10000, 0x80},               // guest-buffer-views
    {0x100000, 0x80},              // guest-set-ids
    {0x200000, 0x200},             // completion-payloads: completion-feed
    {0x400000, 0x200},             // wait-serial
    {0x800000, 0x80 | 0x200},      // silent-success
    {0x1000000, 0x80 | 0x200 | 0x800000},  // one-way-start
};

// `dropped` closed over requirements: every bit that needs a dropped bit is dropped too.
inline constexpr uint32_t closure(uint32_t dropped) {
    for (bool grew = true; grew;) {
        grew = false;
        for (const Requirement& r : kRequirements)
            if ((r.needs & dropped) && !(dropped & r.bit)) { dropped |= r.bit; grew = true; }
    }
    return dropped;
}

inline uint32_t droppedFromEnvironment() {
    static const uint32_t dropped = [] {
        const char* value = std::getenv("CABOOSE_GFXSTREAM_FEATURES_MASK");
        if (!value || !*value) return uint32_t(0);
        const uint32_t closed = closure(uint32_t(std::strtoul(value, nullptr, 0)));
        std::fprintf(stderr, "CABOOSE_GPU_FEATURES_MASK dropped=0x%x\n", closed);
        return closed;
    }();
    return dropped;
}

inline constexpr uint32_t offered(uint32_t offer, uint32_t dropped) { return offer & ~closure(dropped); }

}  // namespace caboose::features
