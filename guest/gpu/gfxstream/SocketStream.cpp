// SPDX-License-Identifier: MIT
#include "SocketStream.h"
#include <cerrno>
#include <cstdlib>
#include <array>
#include <atomic>
#include <cstring>
#include <iterator>
#include <fstream>
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
#include "caboose-shader-cache/shader_cache.h"

// Private diagnostic framing, not the Caboose display protocol. The peer only
// echoes this after verifying its actual immutable features and source pins.
#if defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE) && !defined(CABOOSE_GFXSTREAM_PRIVATE_ICD)
#error Private live transport requires the private diagnostic ICD build
#endif
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI) && (!defined(CABOOSE_GFXSTREAM_PRIVATE_LIVE) || !defined(CABOOSE_GFXSTREAM_PRIVATE_ICD))
#error Private indexed WSI requires the private live diagnostic ICD build
#endif
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
// (the broker ends the streams when it is lost for good). The broker replies with the features both
// the process and the connected phone support. A broker that predates a feature closes
// the connection instead, so the offer falls back to fewer features.
static constexpr uint32_t kGuestHandles = 0x80, kGuestHandleArrays = 0x100, kCompletionFeed = 0x200,
                          kOrderedPresent = 0x400, kGuestImages = 0x800, kGuestQueryPools = 0x1000,
                          kShaderCache = 0x2000, kExecutorResume = 0x4000;
static const uint32_t kOffers[] = {kGuestHandles | kGuestHandleArrays | kCompletionFeed | kOrderedPresent | kGuestImages |
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
// 1 when the phone keeps the shader modules this process sends and takes tokens for the
// ones it holds (hello feature 0x2000; caboose-shader-cache/shader_cache.h).
extern "C" int caboose_gfxstream_shader_cache;
int caboose_gfxstream_shader_cache = 0;
// 1 when the executor resumes and suspends instead of ending (hello feature 0x4000).
extern "C" int caboose_gfxstream_executor_resume;
int caboose_gfxstream_executor_resume = 0;

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
// Opens this process's completion feed stream once, in the background with the hello the
// device stream was granted, and reads its records until the stream ends. Until it is
// running, submissions do not rely on it, so a slow or absent feed never delays a connect.
std::atomic<bool> feedStarted{false};
void startCompletionFeed(const char* path, const unsigned char* granted) {
    if (feedStarted.exchange(true)) return;
    // A child created by fork shares no feed with its parent.
    static const bool atfork = [] {
        pthread_atfork(nullptr, nullptr, [] { caboose::completion::feedActive.store(false); });
        return true;
    }();
    (void)atfork;
    std::string socketPath(path);
    std::array<unsigned char, sizeof(kHello)> offer{};
    std::memcpy(offer.data(), granted, sizeof(kHello));
    std::thread([socketPath, offer] {
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
            return;
        }
        caboose::completion::feedActive.store(true, std::memory_order_release);
        unsigned char record[caboose::completion::kRecordSize];
        while (recvAll(fd, record, sizeof(record))) {
            uint64_t serial;
            int32_t status;
            std::memcpy(&serial, record, sizeof(serial));
            std::memcpy(&status, record + 8, sizeof(status));
            caboose::completion::tracker().complete(serial, status);
        }
        // A feed ends with its executor, or alone (its waits then ask the device).
        caboose::completion::executorEndedIfGone();
        caboose::completion::feedActive.store(false, std::memory_order_release);
        caboose::completion::tracker().feedClosed();
        close(fd);
        feedStarted.store(false);  // a later executor connection runs its own feed
    }).detach();
}
#endif
}  // namespace

// Set on the thread running a connection's hello.
static thread_local bool handshaking = false;
// The process's first connected stream: the shared encoder writes to it.
static std::atomic<CabooseSocketStream*> firstStream{nullptr};
static std::string firstPath;
// The executor is gone. A null read aborts the process in the encoder, so the reply reads
// as VK_ERROR_DEVICE_LOST in every 32-bit word instead: a call's VkResult says the device
// is lost and its other outputs go unused.
static const unsigned char* lostReply(unsigned char* data, size_t len) {
    caboose::completion::awaitExecutorReturn();  // CABOOSE_GPU_ON_LOSS=pause
    const int32_t lost = -4;
    for (size_t i = 0; i < len; ++i) data[i] = reinterpret_cast<const unsigned char*>(&lost)[i % sizeof(lost)];
    return data;
}
CabooseSocketStream::CabooseSocketStream(size_t size) : IOStream(size) {}
CabooseSocketStream::~CabooseSocketStream() {
    // Do not flush during teardown: an interrupted session must not send stale work.
    if (fd_ >= 0 && caboose_gfxstream_device_fd == fd_) caboose_gfxstream_device_fd = -2;
    if (fd_ >= 0) close(fd_);
}
void CabooseSocketStream::invalidate() {
    indexedReady_.store(false, std::memory_order_release);
    if (fd_ >= 0) shutdown(fd_, SHUT_RDWR);
    // A connected device stream ends only when its executor does.
    if (fd_ >= 0 && !handshaking) caboose::completion::markExecutorLost();
}
namespace {
// Processes kept off the phone entirely (guest/gpu/routing-layer, "keptOnComputer": Steam's web
// views and update window; and
// fossilize_replay) do not reach it at all: Steam's update window holds the bootstrap's
// single-instance pipe, so a phone that is slow to answer must never hold it up, and
// fossilize_replay's pipelines would only cross the network to be discarded.
bool keptOffPhone() {
    static const bool kept = [] {
        std::ifstream file("/proc/self/cmdline", std::ios::binary);
        std::string commandLine((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        for (char& c : commandLine) if (c == '\0') c = ' ';
        std::string program = commandLine.substr(0, commandLine.find(' '));
        const auto slash = program.rfind('/');
        if (slash != std::string::npos) program = program.substr(slash + 1);
        const std::string path = commandLine.substr(0, commandLine.find(' '));
        const bool steamClient = program == "steam" &&
            (path.find("/steamrt64/steam") != std::string::npos || path.find("/steamrt32/steam") != std::string::npos);
        return program == "fossilize_replay" || program == "steamwebhelper" || steamClient ||
               commandLine.find(" -child-update-ui") != std::string::npos;
    }();
    return kept;
}
}  // namespace
int CabooseSocketStream::connect(const char* path) {
    if (keptOffPhone()) { errno = ENOENT; return -1; }
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
    if (!exchanged || !acceptedFeatures(offer, reply, guestHandles, &features)) {
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
    caboose_gfxstream_shader_cache = (features & kShaderCache) ? 1 : 0;
    caboose_gfxstream_executor_resume = (features & kExecutorResume) ? 1 : 0;
#else
    caboose_gfxstream_guest_handles = 0;
#endif
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    indexedReady_.store(true, std::memory_order_release);
#endif
    caboose_gfxstream_device_fd = caboose_gfxstream_device_fd == -1 ? fd_ : -2;
    CabooseSocketStream* none = nullptr;
    if (firstStream.compare_exchange_strong(none, this)) firstPath = path;
    // A new executor, perhaps another phone, holds its own shader modules.
    caboose::shader_cache::known().reset();
    caboose::completion::executorConnected();
    caboose::completion::noteExecutorSocket();
#if defined(CABOOSE_GFXSTREAM_PRIVATE_INDEXED_WSI)
    if (features & kCompletionFeed) startCompletionFeed(path, reply);
#endif
    return 0;
}
// Connects the process's first stream (the one its shared encoder writes) again after its
// executor left: 0 when it is connected, else -1 with errno.
extern "C" int caboose_gfxstream_reconnect_ended(void);
extern "C" int caboose_gfxstream_reconnect_ended(void) { return CabooseSocketStream::reconnectEnded(); }
int CabooseSocketStream::reconnectEnded() {
    CabooseSocketStream* stream = firstStream.load();
    if (!stream) { errno = ENOTCONN; return -1; }
    if (stream->indexedHandshakeReady()) return 0;
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
        p += n; len -= static_cast<size_t>(n);
    }
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
    *len = static_cast<size_t>(n);
    return static_cast<const unsigned char*>(data);
}
