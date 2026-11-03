// SPDX-License-Identifier: MIT
#pragma once
// Remote presentation leases own numeric identities and encoded destroy packets only.
// They never own a guest Vulkan wrapper, allocator, callback or user-data pointer.
#include <algorithm>
#include <array>
#include <cstdint>
#include <map>
#include <mutex>
#include <optional>
#include <vector>

namespace caboose::memory {
class PresentationRetirement {
public:
    enum class Kind : uint8_t { Image, Memory, Semaphore, Device, Instance };
    struct Key {
        Kind kind;
        uint64_t id;
        bool operator<(const Key& b) const { return kind!=b.kind ? kind<b.kind : id<b.id; }
    };
    struct Packet {
        // Current private-profile destroys encode at most opcode/size/device/object/null.
        std::array<uint8_t,32> bytes{};
        uint32_t size=0;
        uint64_t allocation=0; // numeric budget-accounting key, not an allocation pointer
    };
    struct Lease { uint64_t generation=0, serial=0; };
    struct Ready { uint64_t generation=0; std::vector<Packet> send, abandoned; };
    static constexpr size_t kMaxLeases=64;
    static constexpr size_t kMaxObjectsPerLease=26; // 8 images/memories/semaphores + device/instance
    static constexpr size_t kMaxRecords=kMaxLeases*kMaxObjectsPerLease;

    // Reserve ownership before accepting work. Exhaustion rejects the new work, never
    // stalls a destroy or creates an unbounded deferred queue.
    std::optional<Lease> reserve(uint64_t generation, const std::vector<Key>& keys) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation!=generation_ || keys.empty() || keys.size()>kMaxObjectsPerLease ||
            leases_.size()>=kMaxLeases || next_==UINT64_MAX) return {};
        auto unique=keys;
        std::sort(unique.begin(),unique.end());
        unique.erase(std::unique(unique.begin(),unique.end(),[](Key a,Key b){return a.kind==b.kind && a.id==b.id;}),unique.end());
        size_t added=0;
        for (Key key:unique) {
            if (!key.id) return {};
            auto it=objects_.find(key);
            if (it==objects_.end()) ++added;
            else if (it->second.packet) return {}; // no new references after guest destruction
        }
        if (objects_.size()+added>kMaxRecords) return {};
        const uint64_t serial=++next_;
        leases_.emplace(serial,unique);
        for (Key key:unique) ++objects_[key].references;
        return Lease{generation,serial};
    }
    // Called only after the matching protocol retirement proof. A reply from another
    // executor generation cannot release an identity reused by the current executor.
    bool release(Lease lease) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (lease.generation!=generation_) return false;
        auto it=leases_.find(lease.serial);
        if (it==leases_.end()) return false;
        for (Key key:it->second) --objects_.at(key).references;
        leases_.erase(it);
        return true;
    }
    // The caller performs guest mapping/allocation destruction synchronously whether
    // this returns true (packet retained) or false (ordinary encoding).
    bool retain(uint64_t generation, Key key, const Packet& packet) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (generation!=generation_ || packet.size<8 || packet.size>packet.bytes.size()) return false;
        auto it=objects_.find(key);
        if (it==objects_.end()) return false;
        if (it->second.packet) return true; // already retained: never encode a duplicate
        it->second.packet=packet;
        return true;
    }
    // A generation transition is proof that none of the old numeric identities can
    // be sent on the new transport. Return accounting records without sending packets.
    Ready changeGeneration(uint64_t generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        Ready result;
        if (generation<=generation_) return result;
        for (const auto& entry:objects_)
            if (entry.second.packet) result.abandoned.push_back(*entry.second.packet);
        objects_.clear(); leases_.clear(); generation_=generation;
        return result;
    }
    // Child objects precede devices, which precede instances. One batch is emitted
    // on one ordered encoder stream before any later destruction batch.
    Ready takeReady(uint64_t generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        Ready result; result.generation=generation;
        if (generation!=generation_) return result;
        for (auto it=objects_.begin();it!=objects_.end();) {
            if (it->second.references) { ++it; continue; }
            if (it->second.packet) result.send.push_back(*it->second.packet);
            it=objects_.erase(it);
        }
        return result;
    }
    size_t leaseCount() const { std::lock_guard<std::mutex> lock(mutex_); return leases_.size(); }
    size_t recordCount() const { std::lock_guard<std::mutex> lock(mutex_); return objects_.size(); }
private:
    struct Object { size_t references=0; std::optional<Packet> packet; };
    mutable std::mutex mutex_;
    uint64_t generation_=0, next_=0;
    std::map<uint64_t,std::vector<Key>> leases_;
    std::map<Key,Object> objects_;
};
// Never destroyed: a process's exit runs static destructors while its other threads may
// still be inside the driver.
inline PresentationRetirement& presentationRetirement = *new PresentationRetirement;
}
