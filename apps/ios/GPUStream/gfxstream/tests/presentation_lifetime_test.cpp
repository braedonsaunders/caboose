// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
#include "presentation_lifetime.h"
#include <cassert>
#include <chrono>
#include <future>
#include <memory>
#include <thread>
using caboose::gpuv2::PresentationLease;
using caboose::gpuv2::PresentationLifetime;
using caboose::gpuv2::PresentationMutation;
int main() {
    auto image = std::make_shared<PresentationLifetime>();
    auto other = std::make_shared<PresentationLifetime>();
    auto lease = std::make_unique<PresentationLease>();
    assert(lease->acquire(image));
    assert(lease->acquire(other));
    { PresentationMutation mutation; assert(!mutation.acquire(other)); }
    image->close();
    auto late = std::make_unique<PresentationLease>();
    assert(!late->acquire(image));
    // Closing one object's gate must not revoke another object's admission.
    assert(late->acquire(other));
    std::promise<void> started;
    auto wait = std::async(std::launch::async, [&] { started.set_value(); image->wait(); });
    started.get_future().wait();
    assert(wait.wait_for(std::chrono::milliseconds(50)) == std::future_status::timeout);
    std::thread release([lease = std::move(lease)]() mutable { lease.reset(); });
    release.join();
    assert(wait.wait_for(std::chrono::seconds(1)) == std::future_status::ready);
    wait.get();
    other->close();
    assert(!std::make_unique<PresentationLease>()->acquire(other));
    late.reset();
    other->wait();
    auto memory = std::make_shared<PresentationLifetime>();
    std::future<void> pending;
    {
        PresentationMutation mutation;
        assert(mutation.acquire(memory));
        assert(mutation.acquire(memory)); // duplicate entries bind once
        PresentationMutation concurrentMutation;
        assert(concurrentMutation.acquire(memory));
        PresentationLease concurrent;
        assert(!concurrent.acquire(memory));
        memory->close();
        pending = std::async(std::launch::async, [&] { memory->wait(); });
        assert(pending.wait_for(std::chrono::milliseconds(50)) == std::future_status::timeout);
    }
    pending.get();
}
