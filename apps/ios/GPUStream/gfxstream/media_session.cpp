// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "media_session.h"
#include "executor_gate.h"
#include "media_stats.h"
#include <cerrno>
#include <deque>
#include <map>
#include <mutex>
#include <new>
#include <sys/socket.h>
#include <unistd.h>

namespace caboose::gpuv2::media {
namespace {
using Clock = std::chrono::steady_clock;

class Session;

// One OPEN stream. The sink outlives the decoder, whose destructor ends its callbacks.
struct Stream final : DecoderSink {
    Session& session;
    uint32_t id;
    bool rejected = false;        // FAIL sent: later units are ignored until CLOSE
    bool replayPending = false;   // REPLAY sent: cleared by the replayed key frame
    std::deque<Clock::time_point> failures;
    std::unique_ptr<Decoder> decoder;
    Stream(Session& s, uint32_t i) : session(s), id(i) {}
    ~Stream() override { decoder.reset(); }
    void decoded(uint32_t surface, uint64_t serial, std::shared_ptr<Picture> picture) override;
    void dropped(uint32_t surface, uint64_t serial) override;
    void failed(uint32_t surface, uint64_t serial) override;
};

class Session {
public:
    Session(int fd, std::atomic_bool& stop, DecoderFactory& factory)
        : fd_(fd), stop_(stop), factory_(factory) {}
    ~Session() {
        streams_.clear();  // every decoder callback has returned after this
        if (hello_) Registry::instance().close(token_);
    }
    int run();
    void send(const std::vector<uint8_t>& bytes) {
        std::lock_guard<std::mutex> lock(writeMutex_);
        if (writeFailed_) return;
        size_t at = 0;
        while (at < bytes.size()) {
#ifdef MSG_NOSIGNAL
            const ssize_t n = ::send(fd_, bytes.data() + at, bytes.size() - at, MSG_NOSIGNAL);
#else
            const ssize_t n = ::send(fd_, bytes.data() + at, bytes.size() - at, 0);
#endif
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { writeFailed_ = true; shutdown(fd_, SHUT_RDWR); return; }
            at += size_t(n);
        }
    }
    // A picture of `stream` failed: count it and answer with REPLAY or FAIL.
    void pictureFailed(Stream& stream, uint32_t surface, uint64_t serial) {
        Registry::instance().failed(token_, surface, serial);
        std::lock_guard<std::mutex> lock(policyMutex_);
        if (stream.rejected) return;
        const auto now = Clock::now();
        stream.failures.push_back(now);
        while (!stream.failures.empty() && now - stream.failures.front() > kFailureWindow)
            stream.failures.pop_front();
        if (stream.failures.size() >= kFailuresBeforeFail) {
            stream.rejected = true;
            send(encodeFail(stream.id, kFailDecode));
        } else if (!stream.replayPending) {
            stream.replayPending = true;
            send(encodeReplay(stream.id));
        }
    }
    const Token& token() const { return token_; }

private:
    // 1 when complete, 0 at the end of the stream before any byte, otherwise -errno
    // (-EPROTO when the stream ends inside the read).
    int readFully(void* data, size_t size) {
        auto* p = static_cast<uint8_t*>(data);
        size_t got = 0;
        while (got < size) {
            ssize_t n;
            {
                ExecutorGate::Idle idle(ExecutorGate::instance());
                n = recv(fd_, p + got, size - got, 0);
            }
            if (n < 0 && errno == EINTR) continue;
            if (n == 0) return got ? -EPROTO : 0;
            if (n < 0) return -errno;
            got += size_t(n);
        }
        return 1;
    }
    int handle(uint32_t type, const uint8_t* p, size_t n);

    int fd_;
    std::atomic_bool& stop_;
    DecoderFactory& factory_;
    std::mutex writeMutex_, policyMutex_;
    bool writeFailed_ = false;
    bool hello_ = false;
    Token token_{};
    std::vector<Capability> caps_;
    std::map<uint32_t, std::unique_ptr<Stream>> streams_;
};

void Stream::decoded(uint32_t surface, uint64_t serial, std::shared_ptr<Picture> picture) {
    Stats::instance().count(Stats::instance().pictures);
    Registry::instance().publish(session.token(), surface, serial, std::move(picture));
}
void Stream::dropped(uint32_t surface, uint64_t serial) {
    Registry::instance().failed(session.token(), surface, serial);
}
void Stream::failed(uint32_t surface, uint64_t serial) {
    Stats::instance().count(Stats::instance().pictureFailures);
    session.pictureFailed(*this, surface, serial);
}

bool supported(const std::vector<Capability>& caps, const Open& o) {
    for (const auto& c : caps)
        if (c.codec == o.codec && o.depth <= c.maxDepth && o.width <= c.maxWidth && o.height <= c.maxHeight)
            return true;
    return false;
}

int Session::handle(uint32_t type, const uint8_t* p, size_t n) {
    if (!hello_) {
        if (type != kHello || !parseHello(p, n, &token_)) return EPROTO;
        hello_ = true;
        Stats::instance().count(Stats::instance().connections);
        Registry::instance().open(token_);
        caps_ = factory_.capabilities();
        send(encodeCaps(caps_));
        return 0;
    }
    switch (type) {
    case kOpen: {
        Open open;
        if (!parseOpen(p, n, &open) || streams_.count(open.stream) || streams_.size() >= kMaxStreams)
            return EPROTO;
        auto stream = std::make_unique<Stream>(*this, open.stream);
        if (supported(caps_, open)) stream->decoder = factory_.create(open, *stream);
        if (!stream->decoder) {
            stream->rejected = true;
            send(encodeFail(open.stream, kFailUnsupported));
        }
        streams_.emplace(open.stream, std::move(stream));
        return 0;
    }
    case kUnit: {
        Unit unit;
        if (!parseUnit(p, n, &unit)) return EPROTO;
        Stats::instance().count(Stats::instance().units);
        Stats::instance().unitBytes.fetch_add(n, std::memory_order_relaxed);
        auto it = streams_.find(unit.stream);
        if (it == streams_.end()) return EPROTO;
        Stream& stream = *it->second;
        {
            std::lock_guard<std::mutex> lock(policyMutex_);
            if (stream.rejected) return 0;
            if ((unit.flags & kUnitReplay) && (unit.flags & kUnitKey)) stream.replayPending = false;
        }
        if (!stream.decoder->decode(unit)) pictureFailed(stream, unit.surface, unit.serial);
        return 0;
    }
    case kClose: {
        uint32_t id;
        if (!parseWord(p, n, &id) || !streams_.count(id)) return EPROTO;
        streams_.erase(id);
        return 0;
    }
    case kSurfaceGone: {
        uint32_t surface;
        if (!parseWord(p, n, &surface)) return EPROTO;
        Registry::instance().forget(token_, surface);
        return 0;
    }
    default:
        return EPROTO;
    }
}

int Session::run() {
    std::vector<uint8_t> payload;
    while (!stop_) {
        uint8_t head[8];
        int r = readFully(head, sizeof(head));
        if (r <= 0) return stop_ ? 0 : -r;
        const uint32_t type = rd32(head), length = rd32(head + 4);
        if (length > kMaxRecord) return EPROTO;
        try { payload.resize(length); } catch (const std::bad_alloc&) { return ENOMEM; }
        if (length && (r = readFully(payload.data(), length)) <= 0) return stop_ ? 0 : (r ? -r : EPROTO);
        // A suspended executor decodes no video (docs/gpu-live.md, "Suspending an executor").
        if (!ExecutorGate::instance().pass(stop_)) return 0;
        if ((r = handle(type, payload.data(), length)) != 0) return r;
    }
    return 0;
}
}

int runMediaSession(int fd, std::atomic_bool& stop, DecoderFactory& factory) {
    try {
        Session session(fd, stop, factory);
        const int result = session.run();
        Stats::instance().report(true);
        return result;
    } catch (const std::bad_alloc&) {
        return ENOMEM;
    }
}
}
