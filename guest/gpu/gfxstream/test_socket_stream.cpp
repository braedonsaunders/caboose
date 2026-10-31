// SPDX-License-Identifier: MIT
// Hello negotiation of the driver's socket transport against a scripted broker.
// Linux only; built with the driver's configuration macros (see README.md).
#include "SocketStream.h"
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
// the reply, or an empty reply to close without answering. After a reply, echoes bytes.
struct Broker {
    std::string path;
    int listener = -1;
    std::vector<Hello> offers;
    std::thread thread;

    Broker(int connections, std::function<Hello(const Hello&)> answer) {
        char directory[] = "/tmp/caboose-socket-stream-XXXXXX";
        assert(mkdtemp(directory));
        path = std::string(directory) + "/gpu";
        listener = socket(AF_UNIX, SOCK_STREAM, 0);
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        std::strcpy(addr.sun_path, path.c_str());
        assert(bind(listener, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) == 0);
        assert(listen(listener, 4) == 0);
        thread = std::thread([this, connections, answer] {
            for (int i = 0; i < connections; ++i) {
                int fd = accept(listener, nullptr, nullptr);
                Hello offer(48);
                if (fd < 0 || !readExactly(fd, offer.data(), offer.size())) { close(fd); return; }
                offers.push_back(offer);
                Hello reply = answer(offer);
                if (reply.empty()) { close(fd); continue; }
                send(fd, reply.data(), reply.size(), MSG_NOSIGNAL);
                unsigned char byte;
                while (recv(fd, &byte, 1, 0) == 1) send(fd, &byte, 1, MSG_NOSIGNAL);
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
    const Hello offered = hello(0xF0), plain = hello(0x70);
    unsetenv("CABOOSE_GFXSTREAM_GUEST_HANDLES");

    // A phone that registers guest-assigned handles: the broker echoes bit 7.
    {
        Broker broker(1, [](const Hello& offer) { return offer; });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 1 && stream->indexedHandshakeReady());
        roundTrip(*stream);
        delete stream;
        assert(broker.offers == std::vector<Hello>{offered});
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
    // A broker that predates bit 7 closes; the driver reconnects offering the plain hello.
    {
        Broker broker(2, [&](const Hello& offer) { return offer == plain ? plain : Hello{}; });
        auto* stream = new CabooseSocketStream(1024);
        assert(stream->connect(broker.path.c_str()) == 0);
        assert(caboose_gfxstream_guest_handles == 0);
        roundTrip(*stream);
        delete stream;
        assert((broker.offers == std::vector<Hello>{offered, plain}));
    }
    // Any other answer fails the connection with EPROTO, after the plain retry.
    {
        Hello wrong = plain;
        wrong.back() ^= 1;
        Broker broker(2, [&](const Hello&) { return wrong; });
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
    return 0;
}
