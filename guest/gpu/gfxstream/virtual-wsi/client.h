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
    // Closes a connection whose bind did not succeed, so that a later bind can be tried.
    void reset();
    bool bound() const { return bound_; }
    Record query(uint64_t request, uint64_t physical, Deadline deadline);
    Record present(const Bytes& suffix, Deadline deadline);
    void waitReleased(uint64_t serial, Deadline deadline);
    uint64_t waitAnyReleased(Deadline deadline);
    // Guest-owned images (MAP flag 1): the guest hands image `index` to the application.
    void acquireLocally(uint64_t swapchain, uint32_t index);
    // Sources still being copied on the phone (not yet released).
    size_t sourcesInFlight() const;
    void consumeRelease(uint64_t serial);
    void waitPresentationIdle(Deadline deadline);
    // Waits until fewer than `frames` presented frames are still unretired.
    void waitPresentationRoom(size_t frames, Deadline deadline);
    Record retire(Deadline deadline);
    bool retired() const { return retired_; }
    // Called when the peer closes the connection (the executor left), before the failure.
    static void (*peerGone)();
    bool revoked() const { return revoked_; }
    bool failed() const { return failed_; }
    Status failure() const { return failure_; }
    bool released(uint64_t serial) const;
    Record createSwapchain(const Bytes& suffix, Deadline deadline);
    // `flags`: 1 guest-owned images (any count up to 8), 2 with it, mailbox drop.
    Record mapSwapchain(uint64_t swapchain, const std::vector<uint64_t>& images, Deadline deadline, uint32_t flags = 0);
    void beginAcquire(uint64_t swapchain, uint64_t request, uint64_t semaphore,
                      uint64_t fence, uint64_t timeout, Deadline deadline);
    void cancelAcquire(uint64_t swapchain, uint64_t request, Deadline deadline);
    Record finishAcquire(uint64_t swapchain, uint64_t request, Deadline deadline);
    // Waits until the outstanding acquire's reply has arrived, without consuming it;
    // false at the deadline, leaving the connection and the acquire intact.
    bool awaitAcquireReply(uint64_t swapchain, Deadline deadline);
    Record presentIndexed(uint64_t swapchain, uint64_t serial, uint64_t queue,
                          uint32_t index, uint32_t family, const std::vector<uint64_t>& waits, Deadline deadline);
    // Sends a present ordered behind device-stream ORDER mark `order` (kind 39) and returns
    // without waiting for its result, which is recorded when it arrives.
    void presentOrdered(uint64_t swapchain, uint64_t serial, uint64_t queue, uint64_t order,
                        uint32_t index, uint32_t family, const std::vector<uint64_t>& waits, Deadline deadline);
    // Processes every record that has already arrived, without blocking.
    void pump();
    // True, with its status, once an ordered present of `swapchain` was not queued.
    bool presentFailed(uint64_t swapchain, Status* status) const;
    Record retireSwapchain(uint64_t swapchain, Deadline deadline);
private:
    void send(uint16_t kind, const Bytes& body, Deadline deadline);
    Record receive(Deadline deadline);
    // Reads one record the socket already holds; false when none was there after all.
    bool receiveReady(Record* out);
    Record await(uint16_t kind, uint64_t serial, Deadline deadline);
    // Like await, but false once the surface is revoked: the phone then owes no
    // further receipts for it.
    bool awaitLive(uint16_t kind, uint64_t serial, Deadline deadline);
    // Applies one received record; true when it is the awaited `kind`/`serial` (kind 0
    // awaits nothing: every record must be unsolicited).
    bool absorb(Record& r, uint16_t kind, uint64_t serial);
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
        // Ordered presents' results arrive later; a failed one never retires.
        bool ordered=false, failed=false;
        uint64_t swapchain=0;
        uint32_t index=0;
    };
    // Rejected ordered presents: their image was never read, so it counts as released.
    std::vector<uint64_t> rejected_;
    bool failed_=false;
    Status failure_{};
    std::map<uint64_t, Source> sources_;
    uint64_t lastSerial_ = 0, lastRequest_ = 0, lastSwapchain_ = 0;
    struct Swapchain {
        uint32_t count;
        bool mapped=false, retiring=false, retired=false;
        uint64_t acquire=0, completedAcquire=0;
        bool presentFailed=false;
        Status presentFailure{};
        bool guestImages=false;
        std::vector<bool> acquired;
        std::vector<uint64_t> releasedSerial;
    };
    std::map<uint64_t,Swapchain> swapchains_;
    std::map<uint64_t,Record> acquireReplies_;
};
}
