// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace caboose::wsi {
using Bytes = std::vector<uint8_t>;
using Identity = std::array<uint8_t, 40>;
constexpr size_t maxPacket = 262144;
struct ProtocolError : std::runtime_error { using runtime_error::runtime_error; };
inline void require(bool yes) { if (!yes) throw ProtocolError("invalid CGLS record"); }
inline uint32_t u32(const Bytes& b, size_t n) {
    require(n <= b.size() && b.size() - n >= 4);
    return uint32_t(b[n]) | uint32_t(b[n+1])<<8 | uint32_t(b[n+2])<<16 | uint32_t(b[n+3])<<24;
}
inline uint64_t u64(const Bytes& b, size_t n) { return u32(b,n) | uint64_t(u32(b,n+4))<<32; }
inline void put32(Bytes& b, uint32_t v) { for (int i=0;i<4;++i) b.push_back(v>>(i*8)); }
inline void put64(Bytes& b, uint64_t v) { put32(b,v); put32(b,v>>32); }
struct Status {
    int32_t nativeError;
    bool hasVk;
    int32_t vk;
    bool success() const { return !nativeError && (!hasVk || vk == 0); }
};
inline Status status(const Bytes& b, size_t n) {
    const uint32_t error=u32(b,n), has=u32(b,n+4), vk=u32(b,n+8);
    require(error <= INT32_MAX && has <= 1 && (has || !vk) && !u32(b,n+12));
    return {int32_t(error), bool(has), int32_t(vk)};
}
inline Identity identity(const Bytes& b, size_t n) {
    require(n <= b.size() && b.size()-n >= 40);
    require(std::any_of(b.begin()+n,b.begin()+n+16,[](auto v){return v;}) &&
            std::any_of(b.begin()+n+16,b.begin()+n+32,[](auto v){return v;}) && u64(b,n+32));
    Identity result; std::copy_n(b.begin()+n,40,result.begin()); return result;
}
inline Bytes packet(uint16_t kind, const Bytes& body = {}) {
    require(body.size() <= maxPacket-16);
    Bytes b={'C','G','L','S',1,0,uint8_t(kind),uint8_t(kind>>8)};
    put32(b,16+body.size()); put32(b,0); b.insert(b.end(),body.begin(),body.end()); return b;
}
struct Record { uint16_t kind; Bytes body; };
inline Record decode(const Bytes& b) {
    require(b.size() >= 16 && b.size() <= maxPacket && b[0]=='C' && b[1]=='G' &&
            b[2]=='L' && b[3]=='S' && b[4]==1 && b[5]==0 && u32(b,8)==b.size() && !u32(b,12));
    Record r{uint16_t(b[6] | uint16_t(b[7])<<8), Bytes(b.begin()+16,b.end())};
    const auto& p=r.body;
    if (r.kind==0x7fff) {
        require(p.size()==16); const auto s=status(p,0);
        require(s.nativeError && !s.hasVk); return r;
    }
    require(r.kind==17 || r.kind==19 || r.kind==21 || r.kind==22 || r.kind==24);
    identity(p,r.kind==17 ? 8 : 0);
    if (r.kind==17) { require(p.size()==64 && u64(p,0)); status(p,48); }
    if (r.kind==24) { require(p.size()==56); status(p,40); }
    if (r.kind==22) require(p.size()==48 && u64(p,40));
    if (r.kind==21) {
        require(p.size()==72 && u64(p,40)); auto s=status(p,48);
        require(u32(p,64)<=2 && u32(p,68)<=2);
        require(u32(p,68)!=1 || (s.hasVk && s.vk==-4));
    }
    if (r.kind==19) {
        require(p.size()>=64 && u64(p,40)); auto s=status(p,48);
        if (!s.success() || !s.hasVk) {
            require(p.size()==64 && (s.nativeError || (s.hasVk && s.vk))); return r;
        }
        require(p.size()>=128);
        auto f=u32(p,116), m=u32(p,120), q=u32(p,124);
        require(f<=4096 && m<=4096 && q<=4096 && p.size()==128+8*f+4*m+16*q);
        std::vector<uint32_t> seen;
        for (size_t n=128+8*f+4*m;n<p.size();n+=16) {
            auto family=u32(p,n);
            require(std::find(seen.begin(),seen.end(),family)==seen.end() && u32(p,n+8) && u32(p,n+12)<=1);
            seen.push_back(family);
        }
    }
    return r;
}
} // namespace caboose::wsi
