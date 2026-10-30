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
    Record bind(uint64_t instance, uint32_t object, uint32_t width, uint32_t height, Deadline deadline);
    Record query(uint64_t request, uint64_t physical, Deadline deadline);
    Record present(const Bytes& suffix, Deadline deadline);
    void waitReleased(uint64_t serial, Deadline deadline);
    void consumeRelease(uint64_t serial);
    Record retire(Deadline deadline);
    bool retired() const { return retired_; }
    bool released(uint64_t serial) const;
private:
    void send(uint16_t kind, const Bytes& body, Deadline deadline);
    Record receive(Deadline deadline);
    Record await(uint16_t kind, uint64_t serial, Deadline deadline);
    void ready(short events, Deadline deadline);
    [[noreturn]] void fail(int error);
    int fd_ = -1;
    bool bound_ = false, retiring_ = false, retired_ = false;
    Identity identity_{};
    struct Source { bool released = false; bool result = false; };
    std::map<uint64_t, Source> sources_;
    uint64_t lastSerial_ = 0, lastQuery_ = 0;
};
}
