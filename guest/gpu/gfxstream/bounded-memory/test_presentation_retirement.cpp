// SPDX-License-Identifier: MIT
#include "presentation_retirement.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <type_traits>
using Ledger=caboose::memory::PresentationRetirement;
static Ledger::Packet packet(uint8_t marker) {
    Ledger::Packet p; p.size=24; p.bytes.fill(marker); p.allocation=marker; return p;
}
int main() {
    static_assert(std::is_trivially_copyable_v<Ledger::Packet>);
    Ledger ledger;
    ledger.changeGeneration(1);
    const std::vector<Ledger::Key> objects={{Ledger::Kind::Image,1},{Ledger::Kind::Memory,2},
        {Ledger::Kind::Semaphore,3},{Ledger::Kind::Device,4},{Ledger::Kind::Instance,5}};
    for (unsigned cycle=0;cycle<10000;++cycle) {
        auto a=ledger.reserve(1,objects), b=ledger.reserve(1,objects);
        assert(a && b && ledger.recordCount()==5);
        // Caller-owned packet storage can disappear immediately after retention.
        for (size_t i=0;i<objects.size();++i) {
            auto p=packet(uint8_t(i+1));
            assert(ledger.retain(1,objects[i],p));
            p.bytes.fill(0); // no delayed reads of caller storage
        }
        assert(!ledger.reserve(1,objects));
        assert(ledger.takeReady(1).send.empty());
        assert(ledger.release(*a));
        assert(!ledger.release(*a));
        assert(ledger.takeReady(1).send.empty());
        assert(ledger.release(*b));
        auto ready=ledger.takeReady(1);
        assert(ready.generation==1 && ready.send.size()==5);
        for (size_t i=0;i<ready.send.size();++i) assert(ready.send[i].bytes[0]==i+1);
        assert(ledger.recordCount()==0 && ledger.leaseCount()==0);
    }
    std::vector<Ledger::Lease> leases;
    for (size_t i=0;i<Ledger::kMaxLeases;++i) {
        auto lease=ledger.reserve(1,objects); assert(lease); leases.push_back(*lease);
    }
    assert(!ledger.reserve(1,objects));
    assert(ledger.retain(1,objects[0],packet(42)));
    auto abandoned=ledger.changeGeneration(2);
    assert(abandoned.send.empty() && abandoned.abandoned.size()==1);
    assert(abandoned.abandoned[0].allocation==42);
    assert(ledger.recordCount()==0 && ledger.leaseCount()==0);
    auto current=ledger.reserve(2,objects); assert(current);
    assert(ledger.changeGeneration(1).abandoned.empty());
    assert(ledger.leaseCount()==1);
    for (auto old:leases) assert(!ledger.release(old));
    assert(!ledger.retain(1,objects[0],packet(11)));
    assert(ledger.takeReady(1).send.empty());
    assert(ledger.release(*current));
    ledger.takeReady(2);
    assert(ledger.recordCount()==0);
    std::cout<<"presentation retirement: 10000 reuse cycles, shared ownership, capacity, copied packets and stale generations passed\n";
}
