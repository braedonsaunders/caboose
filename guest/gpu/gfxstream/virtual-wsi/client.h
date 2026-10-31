// SPDX-License-Identifier: MIT
#pragma once
#include "wire.h"
#include <chrono>
#include <map>

namespace caboose::wsi {
// Serialized by the owning surface. Closing this object is never retirement proof.
class Client {
public:
    using Deadline = std::chrono::steady_clock::time_point;
    Client() = default;
    ~Client();
    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;
    void connect(const char* path, Deadline deadline);
    // The object's namespace: a wl_surface protocol ID, or an X11 window ID.
    enum Space : uint32_t { WaylandSurface = 0, X11Window = 1 };
    Record bind(uint64_t instance, uint32_t object, uint32_t width, uint32_t height, Deadline deadline,
                Space space = WaylandSurface);
    Record query(uint64_t request, uint64_t physical, Deadline deadline);
    Record present(const Bytes& suffix, Deadline deadline);
    void waitReleased(uint64_t serial, Deadline deadline);
    uint64_t waitAnyReleased(Deadline deadline);
    void consumeRelease(uint64_t serial);
    void waitPresentationIdle(Deadline deadline);
    Record retire(Deadline deadline);
    bool retired() const { return retired_; }
    bool revoked() const { return revoked_; }
    bool failed() const { return failed_; }
    Status failure() const { return failure_; }
    bool released(uint64_t serial) const;
    Record createSwapchain(const Bytes& suffix, Deadline deadline);
    Record mapSwapchain(uint64_t swapchain, const std::vector<uint64_t>& images, Deadline deadline);
    void beginAcquire(uint64_t swapchain, uint64_t request, uint64_t semaphore,
                      uint64_t fence, uint64_t timeout, Deadline deadline);
    void cancelAcquire(uint64_t swapchain, uint64_t request, Deadline deadline);
    Record finishAcquire(uint64_t swapchain, uint64_t request, Deadline deadline);
    Record presentIndexed(uint64_t swapchain, uint64_t serial, uint64_t queue,
                          uint32_t index, uint32_t family, const std::vector<uint64_t>& waits, Deadline deadline);
    Record retireSwapchain(uint64_t swapchain, Deadline deadline);
private:
    void send(uint16_t kind, const Bytes& body, Deadline deadline);
    Record receive(Deadline deadline);
    Record await(uint16_t kind, uint64_t serial, Deadline deadline);
    void ready(short events, Deadline deadline);
    [[noreturn]] void fail(int error);
    int fd_ = -1;
    bool bound_ = false, retiring_ = false, retired_ = false;
    bool revoked_ = false;
    Record retirement_{};
    bool releaseWait_ = false;
    Identity identity_{};
    struct Source {
        bool released=false, result=false, event=false, consumed=false;
        uint64_t swapchain=0;
        uint32_t index=0;
    };
    bool failed_=false;
    Status failure_{};
    std::map<uint64_t, Source> sources_;
    uint64_t lastSerial_ = 0, lastRequest_ = 0, lastSwapchain_ = 0;
    struct Swapchain {
        uint32_t count;
        bool mapped=false, retiring=false, retired=false;
        uint64_t acquire=0, completedAcquire=0;
        std::vector<bool> acquired;
        std::vector<uint64_t> releasedSerial;
    };
    std::map<uint64_t,Swapchain> swapchains_;
    std::map<uint64_t,Record> acquireReplies_;
};
}
