// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// Portable fixture for media_session.cpp and media_registry.cpp: a socketpair plays the
// guest's driver against a fake decoder. Covers the CAPS answer, retention and waits, the
// FAIL and REPLAY rules, and rejection of malformed streams.
#include "media_session.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <poll.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

using namespace caboose::gpuv2::media;
using namespace std::chrono_literals;
#define CHECK(c) do { if (!(c)) { std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); std::exit(1); } } while (0)

namespace {
struct FakePicture : Picture { uint8_t value; explicit FakePicture(uint8_t v) : value(v) {} };

// The first data byte says what happens: 0xEE fails at once, 0xEF fails later on another
// thread, 0xED is dropped, anything else decodes to a picture holding that byte.
class FakeDecoder : public Decoder {
public:
    explicit FakeDecoder(DecoderSink& sink) : sink_(sink) {}
    ~FakeDecoder() override { for (auto& t : threads_) t.join(); }
    bool decode(const Unit& u) override {
        const uint8_t b = u.size ? u.data[0] : 0;
        if (b == 0xEE) return false;
        const uint32_t surface = u.surface;
        const uint64_t serial = u.serial;
        if (b == 0xEF) { threads_.emplace_back([this, surface, serial] { sink_.failed(surface, serial); }); return true; }
        if (b == 0xED) { sink_.dropped(surface, serial); return true; }
        threads_.emplace_back([this, surface, serial, b] { sink_.decoded(surface, serial, std::make_shared<FakePicture>(b)); });
        return true;
    }
private:
    DecoderSink& sink_;
    std::vector<std::thread> threads_;
};

class FakeFactory : public DecoderFactory {
public:
    std::vector<Capability> capabilities() override { return {{kH264, 8, 4096, 2304}, {kHEVC, 10, 8192, 4320}}; }
    std::unique_ptr<Decoder> create(const Open&, DecoderSink& sink) override { return std::make_unique<FakeDecoder>(sink); }
};

struct Guest {
    int fd;
    void send(uint32_t type, const std::vector<uint8_t>& payload) {
        auto r = record(type, payload);
        CHECK(::send(fd, r.data(), r.size(), 0) == ssize_t(r.size()));
    }
    // The next record from the phone, or an empty vector after `wait` of silence.
    std::vector<uint8_t> receive(std::chrono::milliseconds wait = 300ms) {
        pollfd p{fd, POLLIN, 0};
        if (poll(&p, 1, int(wait.count())) <= 0) return {};
        uint8_t head[8];
        CHECK(recv(fd, head, 8, MSG_WAITALL) == 8);
        std::vector<uint8_t> r(head, head + 8);
        r.resize(8 + rd32(head + 4));
        if (r.size() > 8) CHECK(recv(fd, r.data() + 8, r.size() - 8, MSG_WAITALL) == ssize_t(r.size() - 8));
        return r;
    }
};

Token token(uint8_t seed) { Token t; for (int i = 0; i < 16; ++i) t[i] = uint8_t(seed + i); return t; }
std::vector<uint8_t> hello(const Token& t) { std::vector<uint8_t> p; put32(p, kVersion); p.insert(p.end(), t.begin(), t.end()); return p; }
std::vector<uint8_t> open(uint32_t stream, uint8_t codec, uint8_t depth = 8) {
    std::vector<uint8_t> p; put32(p, stream); p.push_back(codec); p.push_back(depth); p.push_back(1); p.push_back(0);
    put16(p, 1920); put16(p, 1080); return p;
}
std::vector<uint8_t> unit(uint32_t stream, uint32_t surface, uint64_t serial, uint8_t byte, uint32_t flags = 0) {
    std::vector<uint8_t> p; put32(p, stream); put32(p, uint32_t(serial)); put32(p, surface); put32(p, flags);
    put32(p, uint32_t(serial)); put32(p, uint32_t(serial >> 32)); put16(p, 1920); put16(p, 1080); put32(p, 0);
    p.push_back(byte); return p;
}
std::vector<uint8_t> word(uint32_t v) { std::vector<uint8_t> p; put32(p, v); return p; }

Registry::Wait wait(const Token& t, uint32_t surface, uint64_t serial, uint8_t* value = nullptr,
                    std::chrono::milliseconds limit = 1000ms) {
    std::shared_ptr<Picture> picture;
    auto r = Registry::instance().waitFor(t, surface, serial, std::chrono::steady_clock::now() + limit, &picture);
    if (r == Registry::Wait::ready && value) *value = static_cast<FakePicture&>(*picture).value;
    return r;
}

struct Run {
    int fds[2];
    std::atomic_bool stop{false};
    int result = -1;
    FakeFactory factory;
    std::thread thread;
    Guest guest;
    Run() {
        CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
        guest.fd = fds[0];
        thread = std::thread([this] { result = runMediaSession(fds[1], stop, factory); });
    }
    int finish() {
        shutdown(fds[0], SHUT_WR);
        thread.join();
        close(fds[0]); close(fds[1]);
        return result;
    }
};
}

int main() {
    const Token t = token(0x40);
    {
        Run run;
        Guest& g = run.guest;
        g.send(kHello, hello(t));
        CHECK(g.receive() == encodeCaps(FakeFactory().capabilities()));
        g.send(kOpen, open(1, kH264));
        g.send(kOpen, open(2, kAV1));  // not in CAPS
        CHECK(g.receive() == encodeFail(2, kFailUnsupported));
        g.send(kUnit, unit(2, 9, 1, 0x10));  // ignored: the stream failed
        g.send(kOpen, open(3, kHEVC, 10));

        // Retention and waits.
        g.send(kUnit, unit(1, 100, 5, 0x55, kUnitKey));
        uint8_t value = 0;
        CHECK(wait(t, 100, 5, &value) == Registry::Wait::ready && value == 0x55);
        g.send(kUnit, unit(1, 100, 6, 0x66));
        CHECK(wait(t, 100, 6, &value) == Registry::Wait::ready && value == 0x66);
        CHECK(wait(t, 100, 5) == Registry::Wait::superseded);
        CHECK(wait(t, 100, 7, nullptr, 50ms) == Registry::Wait::timeout);
        CHECK(wait(token(0x90), 100, 5) == Registry::Wait::gone);
        g.send(kUnit, unit(3, 200, 8, 0xED));  // dropped: no wait, no message
        CHECK(wait(t, 200, 8) == Registry::Wait::failed);
        CHECK(g.receive(100ms).empty());
        g.send(kSurfaceGone, word(100));
        g.send(kUnit, unit(3, 202, 9, 0xED));  // records are handled in order: once this one is,
        CHECK(wait(t, 202, 9) == Registry::Wait::failed);
        CHECK(wait(t, 100, 6) == Registry::Wait::failed);  // the forgotten picture no longer waits

        // One failure asks for a replay; failures before the replayed key frame ask no more.
        g.send(kUnit, unit(1, 101, 10, 0xEE));
        CHECK(g.receive() == encodeReplay(1));
        CHECK(wait(t, 101, 10) == Registry::Wait::failed);
        g.send(kUnit, unit(1, 102, 11, 0xEF));
        CHECK(wait(t, 102, 11) == Registry::Wait::failed);
        CHECK(g.receive(100ms).empty());
        g.send(kUnit, unit(1, 103, 12, 0x12, kUnitKey | kUnitReplay));
        CHECK(wait(t, 103, 12) == Registry::Wait::ready);
        // The third failure within ten seconds fails the stream; its later units are ignored.
        g.send(kUnit, unit(1, 104, 13, 0xEE));
        CHECK(g.receive() == encodeFail(1, kFailDecode));
        g.send(kUnit, unit(1, 105, 14, 0x14));
        CHECK(wait(t, 105, 14, nullptr, 100ms) == Registry::Wait::timeout);
        // Another stream is unaffected.
        g.send(kUnit, unit(3, 201, 15, 0x15));
        CHECK(wait(t, 201, 15) == Registry::Wait::ready);
        g.send(kClose, word(3));
        g.send(kClose, word(1));
        CHECK(run.finish() == 0);
        CHECK(wait(t, 201, 15) == Registry::Wait::gone);  // the connection's pictures are dropped
    }
    // Malformed streams end the connection.
    auto rejects = [](auto feed) {
        Run run;
        feed(run.guest);
        return run.finish();
    };
    CHECK(rejects([](Guest& g) { g.send(kOpen, open(1, kH264)); }) == EPROTO);  // before HELLO
    CHECK(rejects([&](Guest& g) { g.send(kHello, hello(t)); g.receive(); g.send(kClose, word(4)); }) == EPROTO);
    CHECK(rejects([&](Guest& g) { g.send(kHello, hello(t)); g.receive(); g.send(kUnit, unit(4, 1, 1, 0)); }) == EPROTO);
    CHECK(rejects([&](Guest& g) { g.send(kHello, hello(t)); g.receive(); g.send(kOpen, open(1, kH264)); g.send(kOpen, open(1, kH264)); }) == EPROTO);
    CHECK(rejects([&](Guest& g) { g.send(kHello, hello(t)); g.receive(); g.send(0x99, {}); }) == EPROTO);
    CHECK(rejects([&](Guest& g) {
        g.send(kHello, hello(t)); g.receive();
        uint8_t head[8]; std::memcpy(head, "\x03\0\0\0", 4); uint32_t big = kMaxRecord + 1; std::memcpy(head + 4, &big, 4);
        CHECK(::send(g.fd, head, 8, 0) == 8);
    }) == EPROTO);
    CHECK(rejects([&](Guest& g) { uint8_t partial[5] = {1, 0, 0, 0, 20}; CHECK(::send(g.fd, partial, 5, 0) == 5); }) == EPROTO);
    std::printf("media session: all checks passed\n");
    return 0;
}
