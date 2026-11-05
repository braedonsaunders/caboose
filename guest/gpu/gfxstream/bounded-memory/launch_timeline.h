// SPDX-License-Identifier: MIT
#pragma once
// A process's start as the driver sees it, always counted (docs/gpu-live.md, "Launch timeline"):
// how long after the process started it made its first instance, device, shader module and
// pipeline and presented its first frame, each written once as
//
//   CABOOSE_GPU_LAUNCH pid=4321 process=MCC-Win64-Shipping event=first_device ms=1234
//
// and, for the first fifteen minutes, every ten seconds in which it made shader modules or
// pipelines, presented or sent commands, what it did in them:
//
//   CABOOSE_GPU_LAUNCH pid=… process=… ms=… window_ms=… modules=… module_bytes=… pipelines=…
//       presents=… commands=… command_bytes=… total_modules=… total_pipelines=… total_presents=…
//
// (the process's id and name, which under Wine is its executable's). A load is then the time
// between those lines and what the process made in it; where the process waited for the
// phone is the read profile's (CABOOSE_READ_PROFILE). Shaders a pipeline carries inline
// (VK_KHR_maintenance5, as DXVK does) are no shader modules: their bytes are the pipeline
// command's.
#include <atomic>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>
#include <unistd.h>

namespace caboose::launch {

enum Event : int { firstInstance, firstDevice, firstModule, firstPipeline, firstPresent, kEvents };
inline const char* eventName(int event) {
    static const char* const names[kEvents] = {"first_instance", "first_device", "first_shader_module",
                                               "first_pipeline", "first_present"};
    return names[event];
}

class Timeline {
public:
    static constexpr int64_t kWindowMs = 10000, kForMs = 15 * 60 * 1000;
    static constexpr uint32_t kCreateInstance = 20000, kCreateDevice = 20011, kCreateShaderModule = 20059,
                              kCreateGraphicsPipelines = 20065, kCreateComputePipelines = 20066;

    // One command encoded `nowMs` after the process started: `bytes` of the device stream.
    void command(uint32_t opcode, uint32_t bytes, int64_t nowMs) {
        commands_.fetch_add(1, std::memory_order_relaxed);
        commandBytes_.fetch_add(bytes, std::memory_order_relaxed);
        switch (opcode) {
            case kCreateInstance: reached(firstInstance, nowMs); break;
            case kCreateDevice: reached(firstDevice, nowMs); break;
            case kCreateShaderModule:
                reached(firstModule, nowMs);
                modules_.fetch_add(1, std::memory_order_relaxed);
                moduleBytes_.fetch_add(bytes, std::memory_order_relaxed);
                totalModules_.fetch_add(1, std::memory_order_relaxed);
                break;
            case kCreateGraphicsPipelines:
            case kCreateComputePipelines:
                reached(firstPipeline, nowMs);
                pipelines_.fetch_add(1, std::memory_order_relaxed);
                totalPipelines_.fetch_add(1, std::memory_order_relaxed);
                break;
            default: break;
        }
    }
    // A frame presented `nowMs` after the process started.
    void presented(int64_t nowMs) {
        reached(firstPresent, nowMs);
        presents_.fetch_add(1, std::memory_order_relaxed);
        totalPresents_.fetch_add(1, std::memory_order_relaxed);
    }

    // The lines due by `nowMs`, each ending in a newline, once: the milestones reached and not
    // yet written, then the window's line when a window has ended in the first fifteen minutes
    // and something happened in it. Empty when nothing is due, or another thread took it.
    std::string take(int64_t nowMs, const std::string& who = std::string()) {
        std::string text;
        char line[512];
        for (int event = 0; event < kEvents; ++event) {
            const int64_t at = at_[event].load(std::memory_order_acquire);
            if (at < 0 || written_[event].exchange(true, std::memory_order_acq_rel)) continue;
            std::snprintf(line, sizeof line, "CABOOSE_GPU_LAUNCH%s event=%s ms=%" PRId64 "\n", who.c_str(),
                          eventName(event), at);
            text += line;
        }
        int64_t start = windowStart_.load(std::memory_order_relaxed);
        if (start < 0) {
            windowStart_.compare_exchange_strong(start, nowMs, std::memory_order_relaxed);
            return text;
        }
        if (nowMs - start < kWindowMs ||
            !windowStart_.compare_exchange_strong(start, nowMs, std::memory_order_relaxed)) return text;
        const uint64_t modules = modules_.exchange(0, std::memory_order_relaxed);
        const uint64_t moduleBytes = moduleBytes_.exchange(0, std::memory_order_relaxed);
        const uint64_t pipelines = pipelines_.exchange(0, std::memory_order_relaxed);
        const uint64_t presents = presents_.exchange(0, std::memory_order_relaxed);
        const uint64_t commands = commands_.exchange(0, std::memory_order_relaxed);
        const uint64_t commandBytes = commandBytes_.exchange(0, std::memory_order_relaxed);
        if (start > kForMs || !(modules || pipelines || presents || commands)) return text;
        std::snprintf(line, sizeof line,
            "CABOOSE_GPU_LAUNCH%s ms=%" PRId64 " window_ms=%" PRId64 " modules=%" PRIu64 " module_bytes=%" PRIu64
            " pipelines=%" PRIu64 " presents=%" PRIu64 " commands=%" PRIu64 " command_bytes=%" PRIu64
            " total_modules=%" PRIu64 " total_pipelines=%" PRIu64 " total_presents=%" PRIu64 "\n",
            who.c_str(), nowMs, nowMs - start, modules, moduleBytes, pipelines, presents, commands, commandBytes,
            totalModules_.load(std::memory_order_relaxed), totalPipelines_.load(std::memory_order_relaxed),
            totalPresents_.load(std::memory_order_relaxed));
        text += line;
        return text;
    }

private:
    void reached(Event event, int64_t nowMs) {
        int64_t unset = -1;
        at_[event].compare_exchange_strong(unset, nowMs, std::memory_order_acq_rel);
    }
    std::atomic<int64_t> at_[kEvents] = {-1, -1, -1, -1, -1};
    std::atomic<bool> written_[kEvents] = {};
    std::atomic<int64_t> windowStart_{-1};
    std::atomic<uint64_t> modules_{0}, moduleBytes_{0}, pipelines_{0}, presents_{0}, commands_{0}, commandBytes_{0};
    std::atomic<uint64_t> totalModules_{0}, totalPipelines_{0}, totalPresents_{0};
};

// Milliseconds since this process started (its start time in /proc/self/stat, against the
// boot clock), or since the first call where that cannot be read.
inline int64_t sinceStartMs() {
    auto bootMs = [] {
        timespec now{};
#ifdef CLOCK_BOOTTIME
        clock_gettime(CLOCK_BOOTTIME, &now);  // the clock /proc/self/stat's start time is on
#else
        clock_gettime(CLOCK_MONOTONIC, &now);
#endif
        return int64_t(now.tv_sec) * 1000 + now.tv_nsec / 1000000;
    };
    static const int64_t startMs = [&] {
        FILE* stat = std::fopen("/proc/self/stat", "r");
        char buffer[1024] = {};
        const size_t read = stat ? std::fread(buffer, 1, sizeof buffer - 1, stat) : 0;
        if (stat) std::fclose(stat);
        // Field 22, after the command name in parentheses (which may hold spaces).
        const char* p = read ? std::strrchr(buffer, ')') : nullptr;
        unsigned long long ticks = 0;
        const long hz = sysconf(_SC_CLK_TCK);
        if (p && hz > 0) {
            int field = 2;
            for (; *p && field < 22; ++p)
                if (*p == ' ') ++field;
            if (field == 22 && std::sscanf(p, "%llu", &ticks) == 1)
                return int64_t(ticks * 1000ull / (unsigned long long)hz);
        }
        return bootMs();
    }();
    return bootMs() - startMs;
}

// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline Timeline& timeline() {
    static Timeline* instance = new Timeline;
    return *instance;
}
inline void command(uint32_t opcode, uint32_t bytes) { timeline().command(opcode, bytes, sinceStartMs()); }
inline void presented() { timeline().presented(sinceStartMs()); }
// " pid=… process=…" for this process: its id and name (/proc/self/comm).
inline const std::string& who() {
    static const std::string value = [] {
        char name[64] = "?";
        if (FILE* comm = std::fopen("/proc/self/comm", "r")) {
            if (std::fgets(name, sizeof name, comm)) name[std::strcspn(name, "\n")] = 0;
            std::fclose(comm);
        }
        for (char* c = name; *c; ++c) if (*c == ' ' || *c == '=') *c = '_';
        return " pid=" + std::to_string(getpid()) + " process=" + name;
    }();
    return value;
}
// Writes the due lines to standard error.
inline void report() {
    const std::string text = timeline().take(sinceStartMs(), who());
    if (text.empty()) return;
    std::fputs(text.c_str(), stderr);
    std::fflush(stderr);
}

}  // namespace caboose::launch
