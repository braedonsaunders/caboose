// SPDX-License-Identifier: MIT
#include "SocketStream.h"
#include <cerrno>
#include <cstdlib>
#include <array>
#include <atomic>
#include <cstring>
#include <cstdio>
#include <exception>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <string>
#include <thread>
#include <unistd.h>
#include "caboose-bounded-memory/completion_feed.h"
#include "caboose-bounded-memory/deferred_replies.h"
#include "caboose-bounded-memory/memory_traffic.h"
#include "caboose-bounded-memory/silent_success.h"
#include "caboose-bounded-memory/upload_cache.h"
#include "caboose-bounded-memory/static_query_cache.h"
#include "caboose-shader-cache/shader_cache.h"

// Private diagnostic framing, not the Caboose display protocol. The peer only
// echoes this after verifying its actual immutable features and source pins.
#if defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE) && !defined(CABOOSE_GFXSTREAM_PRIVATE_ICD)
#error Private live transport requires the private diagnostic ICD build
#endif
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI) && (!defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE) || !defined(CABOOSE_GFXSTREAM_PRIVATE_ICD))
#error Private indexed WSI requires the private live diagnostic ICD build
#endif
static constexpr uint32_t kCacheSession = 0x20000;
static constexpr unsigned char kHello[48] = {
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    'C','B','G','L','R','E','F','1', 4,0,0,0, 0x70,0,0,0,
#elif defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE)
    'C','B','G','L','R','E','F','1', 3,0,0,0, 0x30,0,0,0,
#else
    'C','B','G','L','R','E','F','1', 2,0,0,0, 0x10,0,0,0,
#endif
    0x20,0xd3,0xbb,0x2e,0x30,0x33,0x7c,0xab,
    0xf0,0xfe,0xbb,0x00,0x6e,0xd1,0x02,0xab,
    0x25,0xcc,0xf6,0xd9,0xdd,0xbf,0xaf,0x62,
    0x4c,0x7e,0x68,0xf9,0x04,0x09,0x69,0xc0,
};

#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
// Optional features offered above the required mask, in the hello's 32-bit mask field:
// 0x80 this process assigns its own handles for single-object creates and pipelines;
// 0x100 also for descriptor sets and command buffers; 0x200 it runs a completion feed
// (caboose-bounded-memory/completion_feed.h); 0x400 its presents are ordered behind
// device-stream ORDER marks instead of a drain; 0x800 swapchain images are the guest's own;
// 0x1000 it assigns query pool handles; 0x2000 it names shader modules the phone keeps by
// hash (caboose-shader-cache/shader_cache.h); 0x4000 the executor resumes across a lost
// socket and suspends in the background, so waits for the phone have no deadline of their own
// (the broker ends the streams when it is lost for good); 0x8000 it names 4096-byte pieces of
// flushed memory the phone keeps by hash (caboose-bounded-memory/upload_cache.h); 0x10000 it
// assigns buffer view handles too (requires 0x80); 0x80000 it allocates and writes descriptor
// sets itself, inline uniform blocks included, and sends them with its next submit, in one
// vkQueueCommitDescriptorSetUpdatesGOOGLE (docs/gpu-live.md, "Batched descriptor sets"); 0x100000
// it chooses the set ids of those descriptor pools itself (requires 0x80; docs/gpu-live.md,
// "Guest-chosen set ids"); 0x200000 its completion watches name the queries and coherent
// memory their batches end and write, and the feed's records bring them back (requires 0x200;
// caboose-bounded-memory/completion_payloads.h); 0x400000 it sends WAIT_SERIAL, so a wait may
// report complete a submission whose completion it cannot otherwise observe (requires 0x200;
// caboose-bounded-memory/completion_feed.h, Speculation); 0x800000 its device streams switch to
// silent success, where the phone writes no reply for the commands the process does not wait for
// and reports their failure on the feed (requires 0x80 and 0x200; docs/gpu-live.md, "Silent
// success"). It never offers 0x40000, the same without inline uniform blocks. The broker replies with the features both
// the process and the connected phone support. A broker that predates a feature closes
// the connection instead, so the offer falls back to fewer features.
static constexpr uint32_t kGuestHandles = 0x80, kGuestHandleArrays = 0x100, kCompletionFeed = 0x200,
                          kOrderedPresent = 0x400, kGuestImages = 0x800, kGuestQueryPools = 0x1000,
                          kShaderCache = 0x2000, kExecutorResume = 0x4000, kUploadCache = 0x8000,
                          kGuestBufferViews = 0x10000, kBatchedDescriptorSets = 0x80000,
                          kGuestSetIds = 0x100000, kCompletionPayloads = 0x200000, kWaitSerial = 0x400000,
                          kSilentSuccess = caboose::silent::kHelloBit;
static const uint32_t kOffers[] = {0x3ff80 | kBatchedDescriptorSets | kGuestSetIds | kCompletionPayloads | kWaitSerial | kSilentSuccess,
                                   0x3ff80 | kBatchedDescriptorSets | kGuestSetIds | kCompletionPayloads | kWaitSerial,
                                   0x3ff80 | kBatchedDescriptorSets | kGuestSetIds | kCompletionPayloads,
                                   0x3ff80 | kBatchedDescriptorSets | kGuestSetIds,
                                   0x3ff80 | kBatchedDescriptorSets, 0x3ff80, kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent | kGuestImages |
                                       kGuestQueryPools | kShaderCache | kExecutorResume | kUploadCache |
                                       kGuestBufferViews,
                                   kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent | kGuestImages |
                                       kGuestQueryPools | kShaderCache | kExecutorResume | kUploadCache,
                                   kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent | kGuestImages |
                                       kGuestQueryPools | kShaderCache | kExecutorResume,
                                   kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent | kGuestImages |
                                       kGuestQueryPools | kShaderCache,
                                   kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent | kGuestImages |
                                       kGuestQueryPools,
                                   kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent | kGuestImages,
                                   kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent,
                                   kGuestHandles};
static std::array<unsigned char, sizeof(kHello)> helloWith(uint32_t features) {
    std::array<unsigned char, sizeof(kHello)> hello{};
    std::memcpy(hello.data(), kHello, sizeof(kHello));
    uint32_t mask;
    std::memcpy(&mask, hello.data() + 12, sizeof(mask));
    mask |= features;
    std::memcpy(hello.data() + 12, &mask, sizeof(mask));
    return hello;
}
#endif
// 1 when this process's device stream registers guest-assigned handles.
extern "C" int caboose_gfxstream_guest_handles;
int caboose_gfxstream_guest_handles = 0;
// The descriptor of this process's only device stream; -1 before one connects and -2
// once a second one exists, when no single descriptor carries every reply.
extern "C" int caboose_gfxstream_device_fd;
int caboose_gfxstream_device_fd = -1;
// 1 when it also registers guest-assigned descriptor sets and command buffers.
extern "C" int caboose_gfxstream_guest_handle_arrays;
int caboose_gfxstream_guest_handle_arrays = 0;
// 1 when presents are ordered behind device-stream ORDER marks (SWAPCHAIN_PRESENT_ORDERED).
extern "C" int caboose_gfxstream_ordered_present;
int caboose_gfxstream_ordered_present = 0;
// 1 when swapchain images are the guest's own: acquisition is local and the phone takes
// a native image inside each present (hello feature 0x800).
extern "C" int caboose_gfxstream_guest_images;
int caboose_gfxstream_guest_images = 0;
// 1 when the guest also assigns query pool handles (hello feature 0x1000).
extern "C" int caboose_gfxstream_guest_query_pools;
int caboose_gfxstream_guest_query_pools = 0;
// 1 when the guest also assigns buffer view handles (hello feature 0x10000).
extern "C" int caboose_gfxstream_guest_buffer_views;
int caboose_gfxstream_guest_buffer_views = 0;
// 1 when the phone keeps the shader modules this process sends and takes tokens for the
// ones it holds (hello feature 0x2000; caboose-shader-cache/shader_cache.h).
extern "C" int caboose_gfxstream_shader_cache;
int caboose_gfxstream_shader_cache = 0;
// 1 when the executor resumes and suspends instead of ending (hello feature 0x4000).
extern "C" int caboose_gfxstream_executor_resume;
int caboose_gfxstream_executor_resume = 0;
// 1 when the phone keeps flushed pieces and takes their prefixes (hello feature 0x8000).
extern "C" int caboose_gfxstream_upload_cache;
int caboose_gfxstream_upload_cache = 0;
// 1 while descriptor sets are allocated and written in the guest and sent with the next submit
// (hello feature 0x80000), 0 when not, -1 before the first connection. Each executor
// connection decides it: a process that outlives its executor (the compositor) follows the
// next one, batched or not, and the objects it made under the last are lost with it.
extern "C" int caboose_gfxstream_batched_descriptor_sets;
int caboose_gfxstream_batched_descriptor_sets = -1;
// 1 while this process chooses the set ids of its batched descriptor pools (hello feature
// 0x100000, granted with 0x80). Each executor connection decides it, as for batched sets; each
// pool records how its ids were made.
extern "C" int caboose_gfxstream_guest_set_ids;
int caboose_gfxstream_guest_set_ids = 0;
// 1 while this process's completion watches name what the phone captures for their records
// (hello feature 0x200000, granted with the completion feed 0x200). Each executor connection
// decides it; records are read the same way either way.
extern "C" int caboose_gfxstream_completion_payloads;
int caboose_gfxstream_completion_payloads = 0;
// 1 while this process's device stream takes WAIT_SERIAL (hello feature 0x400000, granted with
// the completion feed 0x200), so its waits may be speculated; each executor connection decides it.
extern "C" int caboose_gfxstream_wait_serial;
int caboose_gfxstream_wait_serial = 0;
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
// Speculated watches whose records are still to come, at most, per queue.
static constexpr uint32_t kSpeculationLimit = 3;
// CABOOSE_GPU_SPECULATE=0 keeps every wait for the phone's records.
static bool speculationAllowed() {
    static const bool allowed = [] {
        const char* value = std::getenv("CABOOSE_GPU_SPECULATE");
        return !(value && std::strcmp(value, "0") == 0);
    }();
    return allowed;
}
#endif

namespace {
// The reply is the required hello with a subset of the offered features; returns them.
bool acceptedFeatures(const unsigned char* offer, const unsigned char* reply, bool optional,
                      uint32_t* features) {
    uint32_t required = 0, offered = 0, accepted = 0;
    std::memcpy(&required, kHello + 12, sizeof(required));
    std::memcpy(&offered, offer + 12, sizeof(offered));
    std::memcpy(&accepted, reply + 12, sizeof(accepted));
    const bool shape = !std::memcmp(reply, kHello, 12) &&
                       !std::memcmp(reply + 16, kHello + 16, sizeof(kHello) - 16);
    *features = accepted & ~required;
    return shape && (accepted & required) == required && !(*features & ~offered) &&
           (optional || !*features);
}

int connectSocket(const char* path) {
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (std::strlen(path) >= sizeof(addr.sun_path)) { errno = ENAMETOOLONG; return -1; }
    std::strcpy(addr.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;
    if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        int error = errno;
        close(fd);
        errno = error;
        return -1;
    }
    return fd;
}

bool sendAll(int fd, const void* data, size_t size) {
    auto p = static_cast<const unsigned char*>(data);
    while (size) {
        ssize_t n = send(fd, p, size, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; size -= static_cast<size_t>(n);
    }
    return true;
}

bool recvAll(int fd, void* data, size_t size) {
    auto p = static_cast<unsigned char*>(data);
    while (size) {
        ssize_t n = recv(fd, p, size, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += n; size -= static_cast<size_t>(n);
    }
    return true;
}

#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
// Opens this process's completion feed stream once per connection generation, in the
// background with the hello the device stream was granted, and reads its records until
// the stream ends. Until it is running, submissions do not rely on it, so a slow or
// absent feed never delays a connect.
std::atomic<uint64_t> feedGeneration{0};
std::atomic<uint64_t> activeFeedGeneration{0};
void startCompletionFeed(const char* path, const unsigned char* granted) {
    const uint64_t generation = feedGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
    uint64_t expected = generation - 1;
    if (!activeFeedGeneration.compare_exchange_strong(expected, generation, std::memory_order_acq_rel)) return;
    // A child created by fork shares no feed with its parent.
    static const bool atfork = [] {
        pthread_atfork(nullptr, nullptr, [] {
            caboose::completion::feedActive.store(false);
            activeFeedGeneration.store(0);
        });
        return true;
    }();
    (void)atfork;
    std::string socketPath(path);
    std::array<unsigned char, sizeof(kHello)> offer{};
    std::memcpy(offer.data(), granted, sizeof(kHello));
    uint32_t feedFeatures=0; std::memcpy(&feedFeatures,offer.data()+12,4);
    feedFeatures &= ~kCacheSession; std::memcpy(offer.data()+12,&feedFeatures,4);
    std::thread([socketPath, offer, generation] {
        int fd = connectSocket(socketPath.c_str());
        unsigned char reply[sizeof(kHello)];
        uint32_t features = 0;
        uint8_t command[caboose::completion::kFeedPacketSize];
        caboose::completion::encodeFeed(command);
        const uint32_t clientFlags = 0;
        if (fd < 0 || !sendAll(fd, offer.data(), offer.size()) || !recvAll(fd, reply, sizeof(reply)) ||
            !acceptedFeatures(offer.data(), reply, true, &features) || !(features & kCompletionFeed) ||
            !sendAll(fd, &clientFlags, sizeof(clientFlags)) || !sendAll(fd, command, sizeof(command))) {
            std::fprintf(stderr, "CABOOSE_COMPLETION_FEED unavailable errno=%d\n", errno);
            if (fd >= 0) close(fd);
            // The current generation has no feed: its waits ask the device. An older feed
            // still marked active would leave watches nobody completes.
            if (feedGeneration.load(std::memory_order_acquire) == generation)
                caboose::completion::feedActive.store(false, std::memory_order_release);
            uint64_t own = generation;
            activeFeedGeneration.compare_exchange_strong(own, 0, std::memory_order_acq_rel);
            return;
        }
        if (feedGeneration.load(std::memory_order_acquire) == generation)
            caboose::completion::feedActive.store(true, std::memory_order_release);
        // Records carry their payloads (caboose-bounded-memory/completion_payloads.h); one
        // that arrives after a later generation took over is not applied. A FAULT (silent
        // success) is the loss of the process's device.
        while (caboose::completion::readRecord([&](void* data, size_t size) {
                   return recvAll(fd, data, size) && feedGeneration.load(std::memory_order_acquire) == generation;
               }, caboose::completion::tracker(), [](uint32_t opcode, int32_t result) {
                   caboose::silent::fault(opcode, result);
               })) {
        }
        // A feed ends with its executor, or alone (its waits then ask the device). An
        // older generation's feed that finishes after a reconnect must not touch the
        // new generation's state.
        if (feedGeneration.load(std::memory_order_acquire) == generation) {
            caboose::completion::executorEndedIfGone();
            // A silent stream's failures are told only on the feed: without it they would go
            // unseen, so the device is lost with it.
            if (caboose::silent::replyMode().anySilent()) {
                std::fprintf(stderr, "CABOOSE_GPU_SILENT_FEED_ENDED\n");
                caboose::completion::markExecutorLost();
            }
            caboose::completion::feedActive.store(false, std::memory_order_release);
            caboose::completion::tracker().feedClosed();
        }
        close(fd);
        uint64_t own = generation;
        activeFeedGeneration.compare_exchange_strong(own, 0, std::memory_order_acq_rel);
    }).detach();
}
#endif
}  // namespace

// Set on the thread running a connection's hello.
static thread_local bool handshaking = false;
// The process's first connected stream: the shared encoder writes to it.
static std::atomic<CabooseSocketStream*> firstStream{nullptr};
// Never destroyed: a reconnect can run while the process exits.
static std::string& firstPath = *new std::string;
// The executor is gone. A null read aborts the process in the encoder, so the reply reads
// as VK_ERROR_DEVICE_LOST in every 32-bit word instead: a call's VkResult says the device
// is lost and its other outputs go unused. A length read from such a reply is that word
// (0xfcffffff, or twice it for 64 bits) times an element size, so a read of a gigabyte or
// more is one sized by the lost reply itself (vkGetPipelineCacheData's data, after its
// size): it is left unwritten, never filled past the caller's buffer.
constexpr size_t kLostReadLimit = size_t(1) << 30;
static const unsigned char* lostReply(unsigned char* data, size_t len) {
    caboose::completion::awaitExecutorReturn();  // CABOOSE_GPU_ON_LOSS=pause
    if (len >= kLostReadLimit) return data;
    const int32_t lost = caboose::completion::lostResult();
    for (size_t i = 0; i < len; ++i) data[i] = reinterpret_cast<const unsigned char*>(&lost)[i % sizeof(lost)];
    return data;
}
// Encoders made on this stream may switch it to silent success (silent_success.h).
CabooseSocketStream::CabooseSocketStream(size_t size) : IOStream(size) {
    caboose::silent::replyMode().deviceStream(static_cast<gfxstream::guest::IOStream*>(this), true);
}
CabooseSocketStream::~CabooseSocketStream() {
    caboose::silent::replyMode().deviceStream(static_cast<gfxstream::guest::IOStream*>(this), false);
    // Do not flush during teardown: an interrupted session must not send stale work.
    CabooseSocketStream* self = this;
    firstStream.compare_exchange_strong(self, nullptr);
    if (fd_ >= 0 && caboose_gfxstream_device_fd == fd_) caboose_gfxstream_device_fd = -2;
    if (fd_ >= 0) close(fd_);
}
void CabooseSocketStream::invalidate() {
    indexedReady_.store(false, std::memory_order_release);
    if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
    // A connected device stream ends only when its executor does.
    if (fd_ >= 0 && !handshaking) caboose::completion::markExecutorLost();
}
int CabooseSocketStream::connect(const char* path) {
    int result = -1;
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    const char* optOut = std::getenv("CABOOSE_GFXSTREAM_GUEST_HANDLES");
    if (!(optOut && std::strcmp(optOut, "0") == 0)) {
        for (uint32_t offer : kOffers) {
            result = connectWith(path, helloWith(offer).data(), true);
            if (result == 0 || errno != EPROTO) break;
        }
    }
    if (result != 0 && (errno == EPROTO || (optOut && std::strcmp(optOut, "0") == 0)))
#endif
        result = connectWith(path, kHello, false);
    // A phone that is there but cannot be reached leaves the process on the computer's
    // own drivers until it relaunches: say why. No socket at all is just no phone.
    if (result != 0 && errno != ENOENT) {
        const int error = errno;
        std::fprintf(stderr, "CABOOSE_GPU_CONNECT_FAILED errno=%d\n", error);
        errno = error;
    }
    return result;
}
int CabooseSocketStream::connectWith(const char* path, const unsigned char* offer, bool guestHandles) {
    // A refused offer ends the connection during the hello: that is no executor loss.
    handshaking = true;
    struct Done { ~Done() { handshaking = false; } } done;
    const uint32_t nativeOne = 1;
    if (*reinterpret_cast<const unsigned char*>(&nativeOne) != 1) { errno = ENOTSUP; return -1; }
    if (!path) path = std::getenv("CABOOSE_GFXSTREAM_SOCKET");
    if (!path || !*path || fd_ >= 0) { errno = EINVAL; return -1; }
    int fd = connectSocket(path);
    if (fd < 0) return -1;
    fd_ = fd;
    unsigned char reply[sizeof(kHello)];
    const bool exchanged = writeFully(offer, sizeof(kHello)) == 0 && readFully(reply, sizeof(reply));
    uint32_t features = 0;
    unsigned char cacheSession[32]{};
    const unsigned char emptySession[32]{};
    if (!exchanged || !acceptedFeatures(offer, reply, guestHandles, &features) ||
        ((features & kCacheSession) && (!readFully(cacheSession,sizeof(cacheSession)) ||
         !std::memcmp(cacheSession,emptySession,sizeof(cacheSession))))) {
        invalidate();
        close(fd_);
        fd_ = -1;
        errno = EPROTO;
        return -1;
    }
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    caboose_gfxstream_guest_handles = (features & kGuestHandles) ? 1 : 0;
    caboose_gfxstream_guest_handle_arrays =
        (features & kGuestHandles) && (features & kGuestHandleArrays) ? 1 : 0;
    caboose_gfxstream_ordered_present = (features & kOrderedPresent) ? 1 : 0;
    caboose_gfxstream_guest_images = (features & kGuestImages) ? 1 : 0;
    caboose_gfxstream_guest_query_pools = (features & kGuestHandles) && (features & kGuestQueryPools) ? 1 : 0;
    caboose_gfxstream_guest_buffer_views = (features & kGuestHandles) && (features & kGuestBufferViews) ? 1 : 0;
    caboose_gfxstream_shader_cache = (features & kShaderCache) ? 1 : 0;
    caboose_gfxstream_executor_resume = (features & kExecutorResume) ? 1 : 0;
    caboose_gfxstream_upload_cache = (features & kUploadCache) ? 1 : 0;
    __atomic_store_n(&caboose_gfxstream_batched_descriptor_sets, (features & kBatchedDescriptorSets) ? 1 : 0,
                     __ATOMIC_RELEASE);
    __atomic_store_n(&caboose_gfxstream_guest_set_ids,
                     (features & kGuestHandles) && (features & kGuestSetIds) ? 1 : 0, __ATOMIC_RELEASE);
    __atomic_store_n(&caboose_gfxstream_completion_payloads,
                     (features & kCompletionFeed) && (features & kCompletionPayloads) ? 1 : 0, __ATOMIC_RELEASE);
    // Silent success needs every create and allocation it covers to use guest handles, and the
    // feed for failures; a stream switches once its feed runs (VkEncoder::lock).
    const uint32_t silentNeeds = kSilentSuccess | kGuestHandles | kGuestHandleArrays | kCompletionFeed |
                                 kGuestQueryPools | kGuestBufferViews;
    caboose::silent::replyMode().granted((features & silentNeeds) == silentNeeds);
    const bool waitSerial = (features & kCompletionFeed) && (features & kWaitSerial);
    __atomic_store_n(&caboose_gfxstream_wait_serial, waitSerial ? 1 : 0, __ATOMIC_RELEASE);
#else
    caboose_gfxstream_guest_handles = 0;
#endif
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    indexedReady_.store(true, std::memory_order_release);
#endif
    // What this process runs with, once per executor connection: a game's log shows whether
    // it has the completion feed (0x200), ordered presents (0x400) and guest images (0x800).
    std::fprintf(stderr, "CABOOSE_GPU_HELLO features=0x%x\n", features);
    caboose_gfxstream_device_fd = caboose_gfxstream_device_fd == -1 ? fd_ : -2;
    CabooseSocketStream* none = nullptr;
    if (firstStream.compare_exchange_strong(none, this)) firstPath = path;
    // A new executor, perhaps another phone, holds its own shader modules.
    caboose::shader_cache::known().reset();
    caboose::upload_cache::inventory().reset();
    if (features & kCacheSession) {
        std::string identity(reinterpret_cast<const char*>(reply),sizeof(reply));
        identity.append(reinterpret_cast<const char*>(cacheSession),sizeof(cacheSession));
        caboose::memory::staticQueryCache.connection(identity.data(),identity.size());
    } else {
        caboose::memory::staticQueryCache.reset();
    }
    caboose::completion::executorConnected();
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    caboose::completion::tracker().speculation(
        __atomic_load_n(&caboose_gfxstream_wait_serial, __ATOMIC_ACQUIRE) && speculationAllowed() ? kSpeculationLimit : 0);
#endif
    caboose::completion::noteExecutorSocket();
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (features & kCompletionFeed) {
        activeFeedGeneration.store(feedGeneration.load(std::memory_order_acquire), std::memory_order_release);
        startCompletionFeed(path, reply);
    }
#endif
    return 0;
}
// Connects the process's first stream (the one its shared encoder writes) again after its
// executor left: 0 when it is connected, else -1 with errno.
extern "C" int caboose_gfxstream_reconnect_ended(void);
extern "C" int caboose_gfxstream_reconnect_ended(void) { return CabooseSocketStream::reconnectEnded(); }
int CabooseSocketStream::reconnectEnded() {
    std::lock_guard<std::mutex> epochLock(caboose::completion::transportEpochMutex);
    CabooseSocketStream* stream = firstStream.load();
    if (!stream) { errno = ENOTCONN; return -1; }
    // A process that made no call since its executor left has not seen the loss: the
    // broker's socket is gone or is a new executor's. Its next instance connects to that.
    caboose::completion::executorEndedIfGone();
    // When the completion feed or a surface socket detected the executor's departure first,
    // every encoder call returned early via lostCall() without touching `stream`, so
    // `stream->indexedReady_` stayed true on the dead socket.
    if (stream->indexedHandshakeReady() &&
        !caboose::completion::executorLost.load(std::memory_order_acquire))
        return 0;
    stream->indexedReady_.store(false, std::memory_order_release);
    // The encoder and its handles stay; the bytes it buffered for the old connection and the
    // replies that connection owed are dropped.
    if (stream->fd_ >= 0) {
        if (caboose_gfxstream_device_fd == stream->fd_) caboose_gfxstream_device_fd = -1;
        close(stream->fd_);
        stream->fd_ = -1;
    }
    stream->rewind();
    caboose::memory::deferredReplies.forgetAll();
    if (stream->connect(firstPath.c_str()) != 0) return -1;
    // The connection manager's first word on a new connection: the client flags (none).
    const uint32_t clientFlags = 0;
    return stream->writeFully(&clientFlags, sizeof(clientFlags));
}
void* CabooseSocketStream::allocBuffer(size_t size) {
    try { buffer_.resize(size); } catch (const std::exception&) { return nullptr; }
    return buffer_.data();
}
int CabooseSocketStream::commitBuffer(size_t size) {
    if (size > buffer_.size()) { errno = EINVAL; return -1; }
    return writeFully(buffer_.data(), size);
}
int CabooseSocketStream::writeFully(const void* data, size_t len) {
    auto p = static_cast<const unsigned char*>(data);
    while (len) {
        ssize_t n = send(fd_, p, len, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { invalidate(); return -1; }
        caboose::memory::traffic::counters().sent(static_cast<uint64_t>(n));
        p += n; len -= static_cast<size_t>(n);
    }
    caboose::memory::traffic::counters().report();
    return 0;
}
const unsigned char* CabooseSocketStream::readFully(void* data, size_t len) {
    auto p = static_cast<unsigned char*>(data);
    auto start = p;
    while (len) {
        ssize_t n = recv(fd_, p, len, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            invalidate();
            if (handshaking) return nullptr;
            return lostReply(start, static_cast<size_t>(p - start) + len);
        }
        caboose::memory::traffic::counters().received(static_cast<uint64_t>(n));
        p += n; len -= static_cast<size_t>(n);
    }
    return start;
}
const unsigned char* CabooseSocketStream::commitBufferAndReadFully(size_t size, void* data, size_t len) {
    if (commitBuffer(size) != 0) {
        if (handshaking) return nullptr;
        return lostReply(static_cast<unsigned char*>(data), len);
    }
    return readFully(data, len);
}
const unsigned char* CabooseSocketStream::read(void* data, size_t* len) {
    if (!data || !len) { errno = EINVAL; return nullptr; }
    ssize_t n;
    do { n = recv(fd_, data, *len, 0); } while (n < 0 && errno == EINTR);
    if (n <= 0) { invalidate(); return nullptr; }
    caboose::memory::traffic::counters().received(static_cast<uint64_t>(n));
    *len = static_cast<size_t>(n);
    return static_cast<const unsigned char*>(data);
}
