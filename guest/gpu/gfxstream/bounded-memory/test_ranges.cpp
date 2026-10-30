// SPDX-License-Identifier: MIT
#include "ranges.h"
#include <cassert>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>
using namespace caboose::memory;

static Range range(const std::shared_ptr<uint8_t>& memory, uint64_t allocation,
                   uint64_t offset, uint64_t size, uint64_t atom = 256) {
    Range r; r.base=memory.get(); r.lifetime=memory; r.allocation=allocation;
    r.mapEnd=allocation; r.offset=offset; r.size=size; r.atom=atom;
    return r;
}
static std::shared_ptr<uint8_t> bytes(size_t size) {
    return {new uint8_t[size], std::default_delete<uint8_t[]>()};
}
int main() {
    constexpr size_t big=32*1024*1024;
    auto memory=bytes(big); std::vector<uint8_t> host(big);
    for (size_t i=0;i<big;++i) memory.get()[i]=uint8_t(i*31+17);
    auto r=range(memory,big,0,0);r.whole=true;
    unsigned calls=0;uint64_t expectedOffset=0;
    auto get=[&](uint32_t,Range& out){out=r;return true;};
    auto flush=[&](uint32_t,uint64_t offset,uint64_t size,uint8_t* destination){
        assert(!destination && offset==expectedOffset && size && size+60<=rpcBytes);
        assert(offset%r.atom==0 && (size%r.atom==0 || offset+size==r.allocation));
        std::memcpy(host.data()+offset,memory.get()+offset,size);
        expectedOffset+=size;++calls;return 0;
    };
    assert(transact(false,1,get,flush)==0 && expectedOffset==big && calls>1);
    assert(!std::memcmp(host.data(),memory.get(),big) && processBudget.used()==0);
    std::memset(memory.get(),0xee,big);calls=0;
    auto invalidate=[&](uint32_t,uint64_t offset,uint64_t size,uint8_t* destination){
        assert(destination && size+12<=rpcBytes && size+52<=rpcBytes);
        assert(memory.get()[0]==0xee && memory.get()[big-1]==0xee);
        std::memcpy(destination,host.data()+offset,size);++calls;return 0;
    };
    assert(transact(true,1,get,invalidate)==0 && calls>1);
    assert(!std::memcmp(host.data(),memory.get(),big) && processBudget.used()==0);
    std::memset(memory.get(),0xdd,big);calls=0;
    assert(transact(true,1,get,[&](uint32_t,uint64_t,uint64_t size,uint8_t* dst){
        std::memset(dst,0,size);return ++calls==2 ? -4 : 0;
    })==-4 && calls==2);
    for(size_t i=0;i<big;++i) assert(memory.get()[i]==0xdd);
    assert(processBudget.used()==0);

    auto small=bytes(4096);std::memset(small.get(),0xa5,4096);
    std::vector<Range> ranges{range(small,4096,0,512),range(small,4096,256,512)};
    assert(transact(true,2,[&](uint32_t i,Range& out){out=ranges[i];return true;},
        [&](uint32_t i,uint64_t,uint64_t size,uint8_t* dst){
            assert(small.get()[256]==0xa5);std::memset(dst,17+i,size);return 0;
        })==0);
    for(unsigned i=0;i<4096;++i) assert(small.get()[i]==(i<256?17:i<768?18:0xa5));
    auto one=[&](Range input, bool valid, uint64_t expectSize){
        unsigned count=0;
        int result=transact(false,1,[&](uint32_t,Range& out){out=input;return true;},
            [&](uint32_t,uint64_t offset,uint64_t size,uint8_t*){
                assert(offset==input.offset && size==expectSize);++count;return 0;
            });
        assert(valid ? result==0 && count==1 : result==outOfHostMemory && count==0);
        assert(processBudget.used()==0);
    };
    auto partial=range(small,4096,768,0);partial.mapBegin=512;partial.mapEnd=1024;partial.whole=true;
    one(partial,true,256);
    auto tail=range(small,1000,768,232);one(tail,true,232);
    tail.whole=true;one(tail,true,232);
    tail.mapEnd=999;one(tail,false,0);
    one(range(small,4096,0,257),false,0);
    one(range(small,4096,1,256),false,0);
    one(range(small,4096,4096,1),false,0);
    auto largeAtom=range(small,131072,0,131072,131072);one(largeAtom,false,0);
    // A short allocation-end range is valid even when the atom exceeds the cap.
    one(range(small,256,0,256,131072),true,256);
    unsigned emitted=0;
    assert(transact(false,2,[&](uint32_t i,Range& out){
        out=range(small,4096,i?1:0,256);return true;
    },[&](uint32_t,uint64_t,uint64_t,uint8_t*){++emitted;return 0;})==outOfHostMemory && emitted==0);
    assert(transact(false,UINT32_MAX,get,flush)==outOfHostMemory);
    assert(processBudget.acquire(stagingBytes));
    assert(transact(true,1,get,invalidate)==outOfHostMemory);
    processBudget.release(stagingBytes);assert(processBudget.used()==0);
    // Metadata counts: precisely the data size alone is not a sufficient budget.
    Budget dataOnly(4096);
    assert(transact(true,1,[&](uint32_t,Range& out){out=range(small,4096,0,4096);return true;},
        [&](uint32_t,uint64_t,uint64_t,uint8_t*){++emitted;return 0;},dataOnly)==outOfHostMemory);
    assert(!emitted && dataOnly.used()==0);

    Budget shared(4096);std::mutex mutex;std::condition_variable changed;bool entered=false,release=false;
    int first=-999;
    auto sharedGet=[&](uint32_t,Range& out){out=range(small,4096,0,2048);return true;};
    std::thread worker([&]{first=transact(true,1,sharedGet,[&](uint32_t,uint64_t,uint64_t size,uint8_t* dst){
        std::unique_lock<std::mutex> lock(mutex);entered=true;changed.notify_all();
        changed.wait(lock,[&]{return release;});std::memset(dst,0x21,size);return 0;
    },shared);});
    {std::unique_lock<std::mutex> lock(mutex);changed.wait(lock,[&]{return entered;});}
    assert(transact(true,1,sharedGet,[&](uint32_t,uint64_t,uint64_t,uint8_t*){++emitted;return 0;},shared)==outOfHostMemory);
    {std::lock_guard<std::mutex> lock(mutex);release=true;}changed.notify_all();worker.join();
    assert(first==0 && !emitted && shared.used()==0 && processBudget.used()==0);
    std::puts("PASS bounded ranges: 32MiB flush/invalidate, atomic failure/overlap, mapping/atom/tail, metadata and concurrent budgets");
}
