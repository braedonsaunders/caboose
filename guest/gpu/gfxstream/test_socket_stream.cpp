// SPDX-License-Identifier: MIT
// Hello negotiation of the driver's socket transport against a scripted broker.
// Linux only; built with the driver's configuration macros (see README.md).
#include "SocketStream.h"
#include "caboose-bounded-memory/completion_feed.h"
#include "caboose-bounded-memory/upload_cache.h"
#include <atomic>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
#include <unistd.h>
#include <vector>

extern "C" int caboose_gfxstream_guest_handles;
extern "C" int caboose_gfxstream_guest_handle_arrays;
extern "C" int caboose_gfxstream_ordered_present;
extern "C" int caboose_gfxstream_shader_cache;
extern "C" int caboose_gfxstream_executor_resume;
extern "C" int caboose_gfxstream_upload_cache;
extern "C" int caboose_gfxstream_guest_buffer_views;
extern "C" int caboose_gfxstream_batched_descriptor_sets;

namespace {
using Hello = std::vector<unsigned char>;

Hello hello(uint32_t mask) {
    Hello bytes = {'C', 'B', 'G', 'L', 'R', 'E', 'F', '1', 4, 0, 0, 0};
    for (int i = 0; i < 4; ++i) bytes.push_back(static_cast<unsigned char>(mask >> (8 * i)));
    // SHA-256 of the pinned source tuple (docs/gpu-live.md).
    const char* fingerprint = "20d3bb2e30337cabf0febb006ed102ab25ccf6d9ddbfaf624c7e68f9040969c0";
    for (int i = 0; i < 32; ++i)
        bytes.push_back(static_cast<unsigned char>(std::stoi(std::string(fingerprint + 2 * i, 2), nullptr, 16)));
    return bytes;
}

bool readExactly(int fd, void* data, size_t size) {
    auto* p = static_cast<unsigned char*>(data);
    while (size) {
        ssize_t n = recv(fd, p, size, 0);
        if (n <= 0) return false;
        p += n; size -= static_cast<size_t>(n);
    }
    return true;
}

// Accepts `connections` clients in turn; `answer` sees each offered hello and returns
// the reply, or an empty reply to close without answering. After a reply, `serve` runs
// on the connection (by default it echoes bytes until the client closes).
struct Broker {
    std::string path;
    int listener = -1;
    std::vector<Hello> offers;
    std::thread thread;

    static void echo(int fd, int) {
        unsigned char byte;
        while (recv(fd, &byte, 1, 0) == 1) send(fd, &byte, 1, MSG_NOSIGNAL);
    }
    Broker(int connections, std::function<Hello(const Hello&)> answer,
           std::function<void(int fd, int index)> serve = echo) {
        char directory[] = "/tmp/caboose-socket-stream-XXXXXX";
        assert(mkdtemp(directory));
        path = std::string(directory) + "/gpu";
        listener = socket(AF_UNIX, SOCK_STREAM, 0);
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        std::strcpy(addr.sun_path, path.c_str());
        assert(bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
        assert(listen(listener, 4) == 0);
        thread = std::thread([this, connections, answer, serve] {
            for (int i = 0; i < connections; ++i) {
                int fd = accept(listener, nullptr, nullptr);
                Hello offer(48);
                if (fd < 0 || !readExactly(fd, offer.data(), offer.size())) { close(fd); return; }
                offers.push_back(offer);
                Hello reply = answer(offer);
                if (reply.empty()) { close(fd); continue; }
                send(fd, reply.data(), reply.size(), MSG_NOSIGNAL);
                serve(fd, i);
                close(fd);
            }
        });
    }
    ~Broker() {
        thread.join();
        close(listener);
        unlink(path.c_str());
        rmdir(path.substr(0, path.rfind('/')).c_str());
    }
};

void roundTrip(CabooseSocketStream& stream) {
    const unsigned char out[4] = {1, 2, 3, 4};
    unsigned char in[4] = {};
    assert(stream.writeFully(out, sizeof(out)) == 0);
    assert(stream.readFully(in, sizeof(in)) && !std::memcmp(in, out, sizeof(out)));
}
}  // namespace

int main() {
    // Everything first (batched descriptor sets with inline uniform blocks, 0x80000), then without them, without buffer views, without the upload cache, without executor
    // resume, without the shader cache, without query pools, without guest images, and guest
    // handles alone for a broker that predates bits 8-16.
    const Hello offered = hello(0xBFFF0), noBatched = hello(0x3FFF0), noCacheSession = hello(0x1FFF0), noBufferViews = hello(0xFFF0), noUpload = hello(0x7FF0), noResume = hello(0x3FF0), noShaderCache = hello(0x1FF0), noQueryPools = hello(0xFF0),
                noGuestImages = hello(0x7F0), handles = hello(0xF0), plain = hello(0x70);
    unsetenv("CABOOSE_GFXSTREAM_GUEST_HANDLES");

    // A phone that registers guest-assigned handles: the broker grants bit 7.
    {
        Broker broker(1, [](const Hello&) { return hello(0xF0); });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 1 && stream->indexedHandshakeReady());
        assert(caboose_gfxstream_guest_handle_arrays == 0 && caboose_gfxstream_ordered_present == 0);
        assert(caboose_gfxstream_shader_cache == 0);
        roundTrip(*stream);
        delete stream;
        assert(broker.offers == std::vector<Hello>{offered});
    }
    // Session trailer is consumed before any encoder bytes. An older broker can
    // refuse the new offer and accept the unchanged prior hello.
    {
        Broker broker(1, [](const Hello&) {
            Hello reply=hello(0x200F0); reply.insert(reply.end(),32,0x5a); return reply;
        });
        CabooseSocketStream stream(1024);
        assert(stream.connect(broker.path.c_str())==0); roundTrip(stream);
    }
    {
        Broker broker(3, [&](const Hello& offer) { return offer==noCacheSession ? handles : Hello{}; });
        CabooseSocketStream stream(1024);
        assert(stream.connect(broker.path.c_str())==0); roundTrip(stream);
        assert((broker.offers==std::vector<Hello>{offered,noBatched,noCacheSession}));
    }
    // A short or zero nonce fails the handshake; fallback must not turn a partial
    // trailer into a Vulkan reply. Every retry is refused in this fixture.
    for (int length : {0,16,32}) {
        Broker broker(11, [length](const Hello&) {
            Hello reply=hello(0x200F0); reply.insert(reply.end(),length,0); return reply;
        }, [](int,int) {});
        CabooseSocketStream stream(1024);
        assert(stream.connect(broker.path.c_str())==-1 && errno==EPROTO);
        assert(!stream.indexedHandshakeReady());
    }
    // An executor that resumes: the broker grants bit 14.
    {
        Broker broker(1, [](const Hello&) { return hello(0x40F0); });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_executor_resume == 1 && caboose_gfxstream_guest_handles == 1);
        roundTrip(*stream);
        delete stream;
    }
    // A phone that keeps shader modules: the broker grants bit 13, with or without handles.
    {
        Broker broker(1, [](const Hello&) { return hello(0x2070); });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_shader_cache == 1 && caboose_gfxstream_guest_handles == 0);
        roundTrip(*stream);
        delete stream;
    }
    // A phone that keeps uploaded pieces: the broker grants bit 15, and every new
    // executor connection forgets the inventory of the last one.
    {
        const uint64_t epoch = caboose::upload_cache::inventory().epoch();
        Broker broker(1, [](const Hello&) { return hello(0x80F0); });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_upload_cache == 1 && caboose_gfxstream_shader_cache == 0);
        assert(caboose::upload_cache::inventory().epoch() == epoch + 1);
        roundTrip(*stream);
        delete stream;
    }
    // A phone that registers buffer views under guest handles: the broker grants bit 16 with bit 7.
    {
        Broker broker(1, [](const Hello&) { return hello(0x100F0); });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_buffer_views == 1 && caboose_gfxstream_guest_handles == 1);
        roundTrip(*stream);
        delete stream;
    }
    // Batched descriptor sets with inline uniform blocks (0x80000) follow each executor
    // connection: granted, then a later executor that does not take them, then one that does
    // again. Every connection succeeds; none is refused.
    {
        caboose_gfxstream_batched_descriptor_sets = -1;
        Broker broker(1, [](const Hello&) { return hello(0x800F0); });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_batched_descriptor_sets == 1);
        roundTrip(*stream);
        delete stream;
    }
    {
        Broker broker(1, [](const Hello&) { return hello(0xF0); });
        CabooseSocketStream stream(1024);
        assert(stream.connect(broker.path.c_str()) == 0 && caboose_gfxstream_batched_descriptor_sets == 0);
        roundTrip(stream);
    }
    {
        Broker broker(1, [](const Hello&) { return hello(0x800F0); });
        CabooseSocketStream stream(1024);
        assert(stream.connect(broker.path.c_str()) == 0 && caboose_gfxstream_batched_descriptor_sets == 1);
        roundTrip(stream);
    }
    // 0x40000 (batched without inline uniform blocks) is never offered: a broker that grants
    // it grants what was not offered, and the offer falls back.
    {
        Broker broker(2, [answered = 0](const Hello&) mutable { return answered++ ? hello(0xF0) : hello(0x400F0); });
        CabooseSocketStream stream(1024);
        assert(stream.connect(broker.path.c_str()) == 0 && caboose_gfxstream_batched_descriptor_sets == 0);
    }
    caboose_gfxstream_batched_descriptor_sets = -1;
    // Arrays and ordered presents are granted with guest handles; a broker cannot grant
    // a feature that was not offered.
    {
        Broker broker(1, [](const Hello&) { return hello(0x5F0); });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 1 && caboose_gfxstream_guest_handle_arrays == 1 &&
               caboose_gfxstream_ordered_present == 1);
        delete stream;
    }
    // With the completion feed granted, a second stream with the granted hello runs the
    // feed: client flags, then COMPLETION_FEED, then records from the phone.
    {
        std::atomic<bool> feedChecked{false};
        Broker broker(2, [](const Hello&) { return hello(0x270); }, [&](int fd, int index) {
            if (index == 0) { Broker::echo(fd, index); return; }
            unsigned char head[4 + caboose::completion::kFeedPacketSize];
            assert(readExactly(fd, head, sizeof(head)));
            uint8_t expected[caboose::completion::kFeedPacketSize];
            caboose::completion::encodeFeed(expected);
            assert(!std::memcmp(head, "\0\0\0\0", 4) && !std::memcmp(head + 4, expected, sizeof(expected)));
            feedChecked = true;
            // One record for a serial nobody watches, then the phone ends the feed.
            unsigned char record[caboose::completion::kRecordSize] = {};
            record[0] = 9;
            send(fd, record, sizeof(record), MSG_NOSIGNAL);
        });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        roundTrip(*stream);
        delete stream;
        for (int i = 0; i < 500 && !feedChecked; ++i) usleep(10000);
        assert(feedChecked);
        for (int i = 0; i < 500 && caboose::completion::feedActive.load(); ++i) usleep(10000);
        assert(!caboose::completion::feedActive.load());
        assert(broker.offers.size() == 2 && broker.offers[1] == hello(0x270));
    }
    // A phone without guest handles: the broker answers the plain hello on the same connection.
    {
        Broker broker(1, [&](const Hello&) { return plain; });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 0 && stream->indexedHandshakeReady());
        roundTrip(*stream);
        delete stream;
    }
    // A broker that knows only bit 7 closes on the full offer and grants guest handles.
    {
        Broker broker(10, [&](const Hello& offer) { return offer == handles ? handles : Hello{}; });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 1 && caboose_gfxstream_guest_handle_arrays == 0);
        roundTrip(*stream);
        delete stream;
        assert((broker.offers == std::vector<Hello>{offered, noBatched, noCacheSession, noBufferViews, noUpload, noResume, noShaderCache, noQueryPools, noGuestImages, handles}));
    }
    // A broker that predates bit 7 closes; the driver reconnects offering the plain hello.
    {
        Broker broker(11, [&](const Hello& offer) { return offer == plain ? plain : Hello{}; });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 0);
        roundTrip(*stream);
        delete stream;
        assert((broker.offers == std::vector<Hello>{offered, noBatched, noCacheSession, noBufferViews, noUpload, noResume, noShaderCache, noQueryPools, noGuestImages, handles, plain}));
    }
    // An answer granting what was not offered, or any other difference, fails the
    // connection with EPROTO, after the plain retry.
    {
        Broker broker(11, [&](const Hello&) { return hello(0x100070); });
        auto* stream = new CabooseSocketStream(1024);
        errno = 0;
        assert(stream->connect(broker.path.c_str()) == -1 && errno == EPROTO);
        delete stream;
    }
    {
        Hello wrong = plain;
        wrong.back() ^= 1;
        Broker broker(11, [&](const Hello&) { return wrong; });
        auto* stream = new CabooseSocketStream(1024);
        errno = 0;
        assert(stream->connect(broker.path.c_str()) == -1 && errno == EPROTO);
        assert(!stream->indexedHandshakeReady());
        delete stream;
    }
    // CABOOSE_GFXSTREAM_GUEST_HANDLES=0 offers only the plain hello.
    {
        setenv("CABOOSE_GFXSTREAM_GUEST_HANDLES", "0", 1);
        Broker broker(1, [](const Hello& offer) { return offer; });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 0);
        delete stream;
        assert(broker.offers == std::vector<Hello>{plain});
        unsetenv("CABOOSE_GFXSTREAM_GUEST_HANDLES");
    }
    // A missing socket is an ordinary connection failure, not a protocol error.
    {
        auto* stream = new CabooseSocketStream(1024);
        errno = 0;
        assert(stream->connect("/tmp/caboose-socket-stream-absent/gpu") == -1 && errno == ENOENT);
        delete stream;
    }
    // When the completion feed or a surface socket marks the executor lost before any
    // encoder call touches `firstStream` (because lostCall() short-circuits every call
    // during teardown), `stream->indexedHandshakeReady()` is still true. `reconnectEnded()`
    // must still close the dead socket, reconnect to the returned executor, send clientFlags,
    // and clear `executorLost`.
    {
        Broker broker(2, [](const Hello&) { return hello(0xF0); }, [](int fd, int index) {
            if (index == 1) {
                uint32_t clientFlags = 0xdeadbeef;
                assert(readExactly(fd, &clientFlags, sizeof(clientFlags)) && clientFlags == 0);
            }
            Broker::echo(fd, index);
        });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(stream->indexedHandshakeReady() && !caboose::completion::executorLost.load());
        // Simulate executor loss detected via the completion feed / surface socket while
        // `stream->invalidate()` was never called because `lostCall()` intercepted teardown.
        caboose::completion::markExecutorLost();
        assert(caboose::completion::executorLost.load());
        assert(caboose::completion::lostCall("vkDestroyDevice"));
        assert(stream->indexedHandshakeReady());
        // Now the compositor creates a new instance after the executor returns.
        assert(CabooseSocketStream::reconnectEnded() == 0);
        assert(!caboose::completion::executorLost.load());
        assert(!caboose::completion::lostCall("vkCreateInstance"));
        assert(stream->indexedHandshakeReady());
        roundTrip(*stream);
        delete stream;
        assert(broker.offers.size() == 2);
    }
    // The executor leaves (last: it marks the process's executor lost). A reply reads as
    // VK_ERROR_DEVICE_LOST in every word; a read sized by such a reply writes nothing.
    {
        Broker broker(1, [](const Hello&) { return hello(0x70); }, [](int, int) {});
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        int32_t words[2] = {};
        assert(stream->readFully(words, sizeof(words)) && words[0] == -4 && words[1] == -4);
        unsigned char data[16];
        std::memset(data, 0x5a, sizeof(data));
        uint64_t size = 0;
        std::memcpy(&size, words, sizeof(size));
        assert(stream->readFully(data, static_cast<size_t>(size)) == data);
        for (unsigned char byte : data) assert(byte == 0x5a);
        delete stream;
    }
    return 0;
}
