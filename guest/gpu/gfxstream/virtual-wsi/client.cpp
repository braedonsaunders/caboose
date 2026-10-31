// SPDX-License-Identifier: MIT
#include "client.h"
#include <cerrno>
#include <climits>
#include <cstring>
#include <poll.h>
#include <system_error>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace caboose::wsi {
Client::~Client() { if (fd_>=0) close(fd_); }
[[noreturn]] void Client::fail(int error) {
    if (fd_>=0) { close(fd_); fd_=-1; }
    throw std::system_error(error, std::generic_category(), "Caboose surface transport");
}
void Client::ready(short events, Deadline deadline) {
    for (;;) {
        auto left=std::chrono::duration_cast<std::chrono::milliseconds>(deadline-std::chrono::steady_clock::now()).count();
        if (left<=0 && !releaseWait_) fail(ETIMEDOUT);
        pollfd p{fd_,events,0};
        int result=poll(&p,1,int(std::max<int64_t>(0,std::min<int64_t>(left,INT_MAX))));
        if (result<0 && errno==EINTR) continue;
        if (result<0) fail(errno);
        if (!result) {
            if (releaseWait_) throw std::system_error(ETIMEDOUT, std::generic_category());
            fail(ETIMEDOUT);
        }
        if (p.revents & events) return;
        fail(ECONNRESET);
    }
}
void Client::connect(const char* path, Deadline deadline) {
    require(fd_<0 && !bound_ && path && *path);
    sockaddr_un address{}; address.sun_family=AF_UNIX;
    require(strlen(path)<sizeof(address.sun_path)); strcpy(address.sun_path,path);
    fd_=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC|SOCK_NONBLOCK,0);
    if (fd_<0) fail(errno);
    if (::connect(fd_,reinterpret_cast<sockaddr*>(&address),sizeof(address))<0) {
        // AF_UNIX EAGAIN means the listen backlog is full, not a pending connect.
        if (errno!=EINPROGRESS) fail(errno);
        ready(POLLOUT,deadline);
        int error=0; socklen_t size=sizeof(error);
        if (getsockopt(fd_,SOL_SOCKET,SO_ERROR,&error,&size)<0) fail(errno);
        if (error) fail(error);
    }
}
void Client::send(uint16_t kind, const Bytes& body, Deadline deadline) {
    require(fd_>=0);
    auto bytes=packet(kind,body);
    for (;;) {
        ready(POLLOUT,deadline);
        ssize_t n=::send(fd_,bytes.data(),bytes.size(),MSG_NOSIGNAL);
        if (n<0 && (errno==EINTR || errno==EAGAIN)) continue;
        if (n<0) fail(errno);
        if (size_t(n)!=bytes.size()) fail(EPROTO);
        return;
    }
}
Record Client::receive(Deadline deadline) {
    require(fd_>=0);
    Bytes bytes(maxPacket);
    for (;;) {
        ready(POLLIN,deadline);
        iovec io{bytes.data(),bytes.size()};
        // No ancillary buffer: unexpected descriptors are discarded by the kernel
        // and MSG_CTRUNC causes rejection, without leaking received descriptors.
        msghdr msg{}; msg.msg_iov=&io; msg.msg_iovlen=1;
        ssize_t n=recvmsg(fd_,&msg,0);
        if (n<0 && (errno==EINTR || errno==EAGAIN)) continue;
        if (n<0) fail(errno);
        if (!n) fail(ECONNRESET);
        if (msg.msg_flags & (MSG_TRUNC|MSG_CTRUNC)) fail(EPROTO);
        bytes.resize(n);
        try { return decode(bytes); } catch (const ProtocolError&) { fail(EPROTO); }
    }
}
Record Client::await(uint16_t kind, uint64_t serial, Deadline deadline) {
    if (kind==30 && acquireReplies_.count(serial)) {
        auto r=std::move(acquireReplies_.at(serial)); acquireReplies_.erase(serial); return r;
    }
    for (;;) {
        auto r=receive(deadline);
        if (r.kind==0x7fff) fail(status(r.body,0).nativeError);
        if (bound_ && identity(r.body,r.kind==17?8:0)!=identity_) fail(EPROTO);
        if (r.kind==35) { revoked_=true; continue; }
        if (r.kind==36) {
            auto id=u64(r.body,40), frame=u64(r.body,48);
            auto found=sources_.find(frame);
            if (found==sources_.end() || found->second.swapchain!=id ||
                !found->second.result || !found->second.released) fail(EPROTO);
            sources_.erase(found);
            if (kind==36) return r;
            continue;
        }
        if (r.kind==21 && u32(r.body,68)!=0) {
            auto found=sources_.find(u64(r.body,40));
            if (found==sources_.end() || found->second.event) fail(EPROTO);
            found->second.event=true; failed_=true; failure_=status(r.body,48);
            // Async failures do not overwrite the one submission response.
            if (kind!=21 || serial!=u64(r.body,40) || found->second.result) continue;
        }
        if (r.kind==24) {
            retirement_=r; retired_=status(r.body,40).success();
            if (kind!=24) fail(ECANCELED);
        }
        if (r.kind==30 && (kind!=30 || u64(r.body,40)!=serial)) {
            auto id=u64(r.body,40);
            if (!swapchains_.count(id) || swapchains_.at(id).acquire!=u64(r.body,48) ||
                acquireReplies_.count(id) || acquireReplies_.size()>=64) fail(EPROTO);
            acquireReplies_.emplace(id,std::move(r)); continue;
        }
        if (r.kind==22) {
            auto it=sources_.find(u64(r.body,40));
            if (it==sources_.end() || it->second.released) fail(EPROTO);
            it->second.released=true;
            if (it->second.swapchain)
                swapchains_.at(it->second.swapchain).releasedSerial.at(it->second.index)=u64(r.body,40);
            if (kind==22 && (!serial || u64(r.body,40)==serial)) return r;
            continue;
        }
        if (r.kind!=kind || (serial && u64(r.body,40)!=serial)) fail(EPROTO);
        return r;
    }
}
Record Client::bind(uint64_t instance, uint32_t object, uint32_t width, uint32_t height, Deadline deadline,
                    Space space) {
    require(!bound_ && instance && object && bool(width)==bool(height) &&
            (space==WaylandSurface || space==X11Window));
    Bytes p; put64(p,instance); put32(p,object); put32(p,width); put32(p,height); put32(p,space);
    send(16,p,deadline); auto r=await(17,0,deadline);
    if (status(r.body,48).success()) { identity_=identity(r.body,8); bound_=true; }
    return r;
}
Record Client::query(uint64_t request, uint64_t physical, Deadline deadline) {
    require(bound_ && !retiring_ && !revoked_ && request>lastRequest_ && physical);
    lastRequest_=request;
    Bytes p; put64(p,request); put64(p,physical); send(18,p,deadline);
    return await(19,request,deadline);
}
Record Client::present(const Bytes& p, Deadline deadline) {
    require(bound_ && !retiring_ && !revoked_ && p.size()>=56);
    const uint64_t serial=u64(p,0);
    const uint32_t count=u32(p,52);
    require(serial>lastSerial_ && u64(p,8) && u64(p,16) && u64(p,24) &&
            u32(p,32) && u32(p,36) && u32(p,40) && u32(p,44)==1 &&
            count<=64 && p.size()==56+8*count);
    std::vector<uint64_t> waits;
    for (size_t i=56;i<p.size();i+=8) {
        auto wait=u64(p,i); require(wait && std::find(waits.begin(),waits.end(),wait)==waits.end());
        waits.push_back(wait);
    }
    require(sources_.size()<64);
    sources_.emplace(serial,Source{}); lastSerial_=serial;
    send(20,p,deadline); auto r=await(21,serial,deadline);
    sources_.at(serial).result=true;
    // Even an unsuccessful PRESENT_RESULT is not SOURCE_RELEASED.
    return r;
}
bool Client::released(uint64_t serial) const {
    if (!serial) return false;
    auto it=sources_.find(serial);
    if (it!=sources_.end() && it->second.released && !it->second.consumed) return true;
    for (const auto& item:swapchains_)
        if (std::find(item.second.releasedSerial.begin(),item.second.releasedSerial.end(),serial)!=item.second.releasedSerial.end()) return true;
    return false;
}
void Client::waitReleased(uint64_t serial, Deadline deadline) {
    require(bound_ && (sources_.count(serial) || released(serial)));
    releaseWait_=true;
    try { if (!released(serial)) await(22,serial,deadline); }
    catch (...) { releaseWait_=false; throw; }
    releaseWait_=false;
}
uint64_t Client::waitAnyReleased(Deadline deadline) {
    require(bound_);
    for (const auto& item:swapchains_)
        for (auto serial:item.second.releasedSerial) if (serial) return serial;
    require(!sources_.empty());
    for (const auto& item:sources_) if (item.second.released && !item.second.consumed) return item.first;
    releaseWait_=true;
    try {
        auto result=await(22,0,deadline); releaseWait_=false; return u64(result.body,40);
    } catch (...) { releaseWait_=false; throw; }
}
void Client::consumeRelease(uint64_t serial) {
    require(released(serial));
    auto found=sources_.find(serial);
    if (found!=sources_.end()) {
        require(found->second.result);
        if (!found->second.swapchain) { sources_.erase(found); return; }
        found->second.consumed=true;
    }
    for (auto& item:swapchains_)
        for (auto& value:item.second.releasedSerial) if (value==serial) value=0;
}
void Client::waitPresentationIdle(Deadline deadline) {
    require(bound_);
    while (std::any_of(sources_.begin(),sources_.end(),[](const auto& entry) {
        return entry.second.swapchain!=0;
    })) await(36,0,deadline);
}
Record Client::retire(Deadline deadline) {
    if (retired_) return retirement_;
    require(bound_ && !retiring_);
    retiring_=true;
    if (!revoked_) send(23,{},deadline);
    auto r=await(24,0,deadline);
    retired_=status(r.body,40).success();
    return r;
}
Record Client::createSwapchain(const Bytes& p, Deadline deadline) {
    require(bound_ && !retiring_ && !revoked_ && p.size()>=80);
    auto request=u64(p,0), device=u64(p,8), old=u64(p,16);
    require(request>lastRequest_ && device && (!old || swapchains_.count(old)));
    for (auto offset:{28,32,40,44,48,52}) require(u32(p,offset));
    auto sharing=u32(p,72), count=u32(p,76);
    require(u32(p,68)<=1 && sharing<=1 && count<=64 && p.size()==80+4*count);
    require((!sharing && !count) || (sharing==1 && count>=2));
    std::vector<uint32_t> families;
    for (uint32_t i=0;i<count;++i) {
        auto family=u32(p,80+4*i);
        require(std::find(families.begin(),families.end(),family)==families.end()); families.push_back(family);
    }
    require(swapchains_.size()<64);
    lastRequest_=request; send(25,p,deadline); auto r=await(26,request,deadline);
    if (status(r.body,56).success()) {
        auto id=u64(r.body,48); auto actual=u32(r.body,72);
        if (id<=lastSwapchain_ || actual<u32(p,28)) fail(EPROTO);
        lastSwapchain_=id;
        Swapchain state{}; state.count=actual; state.acquired.resize(actual,false); state.releasedSerial.resize(actual,0);
        swapchains_.emplace(id,std::move(state));
    }
    return r;
}
Record Client::mapSwapchain(uint64_t id, const std::vector<uint64_t>& images, Deadline deadline) {
    require(bound_ && !retiring_ && !revoked_ && swapchains_.count(id));
    auto& swap=swapchains_.at(id);
    require(!swap.mapped && !swap.retiring && images.size()==swap.count);
    auto sorted=images; std::sort(sorted.begin(),sorted.end());
    require(!sorted.empty() && sorted[0] && std::adjacent_find(sorted.begin(),sorted.end())==sorted.end());
    Bytes p; put64(p,id); put32(p,images.size()); put32(p,0);
    for (auto image:images) put64(p,image);
    send(27,p,deadline); auto r=await(28,id,deadline);
    swap.mapped=status(r.body,48).success(); return r;
}
void Client::beginAcquire(uint64_t id, uint64_t request, uint64_t semaphore,
                          uint64_t fence, uint64_t timeout, Deadline deadline) {
    require(bound_ && !retiring_ && !revoked_ && swapchains_.count(id) && request>lastRequest_ && (semaphore || fence));
    auto& swap=swapchains_.at(id); require(swap.mapped && !swap.retiring && !swap.acquire);
    swap.acquire=request; lastRequest_=request;
    Bytes p; for (auto value:{id,request,semaphore,fence,timeout}) put64(p,value);
    put32(p,1); put32(p,0); send(29,p,deadline);
}
void Client::cancelAcquire(uint64_t id, uint64_t request, Deadline deadline) {
    require(bound_ && swapchains_.count(id)); auto& swap=swapchains_.at(id);
    require(request && (swap.acquire==request || swap.completedAcquire==request));
    if (swap.completedAcquire==request) return;
    Bytes p; put64(p,id); put64(p,request); send(31,p,deadline);
}
Record Client::finishAcquire(uint64_t id, uint64_t request, Deadline deadline) {
    require(bound_ && swapchains_.count(id) && swapchains_.at(id).acquire==request);
    auto r=await(30,id,deadline); auto& swap=swapchains_.at(id);
    if (u64(r.body,48)!=request) fail(EPROTO);
    if (u32(r.body,72)) {
        auto index=u32(r.body,76);
        if (index>=swap.count || swap.acquired[index]) fail(EPROTO);
        swap.acquired[index]=true;
    }
    swap.acquire=0; swap.completedAcquire=request; return r;
}
Record Client::presentIndexed(uint64_t id, uint64_t serial, uint64_t queue,
    uint32_t index, uint32_t family, const std::vector<uint64_t>& waits, Deadline deadline) {
    require(bound_ && !retiring_ && !revoked_ && swapchains_.count(id) && queue && serial>lastSerial_);
    auto& swap=swapchains_.at(id);
    require(swap.mapped && !swap.retiring && index<swap.count && swap.acquired[index] && waits.size()<=64);
    auto sorted=waits; std::sort(sorted.begin(),sorted.end());
    require(sorted.empty() || (sorted[0] && std::adjacent_find(sorted.begin(),sorted.end())==sorted.end()));
    require(sources_.size()<64);
    Bytes p; put64(p,id); put64(p,serial); put64(p,queue);
    put32(p,index); put32(p,family); put32(p,1); put32(p,waits.size());
    for (auto wait:waits) put64(p,wait);
    Source source{}; source.swapchain=id; source.index=index;
    sources_.emplace(serial,source); lastSerial_=serial;
    // Never retry an uncertain transmission, even if no submission reply arrives.
    send(34,p,deadline); auto r=await(21,serial,deadline);
    sources_.at(serial).result=true;
    if (u32(r.body,64)==1) swap.acquired[index]=false;
    else {
        swap.retiring=true;
        if (u32(r.body,64)==0) sources_.erase(serial);
    }
    return r;
}
Record Client::retireSwapchain(uint64_t id, Deadline deadline) {
    require(bound_ && swapchains_.count(id)); auto& swap=swapchains_.at(id);
    require(!swap.retired && !swap.acquire);
    swap.retiring=true; Bytes p; put64(p,id); send(32,p,deadline);
    auto r=await(33,id,deadline); swap.retired=status(r.body,48).success();
    if (swap.retired) {
        for (const auto& frame:sources_) if (frame.second.swapchain==id) fail(EPROTO);
        swapchains_.erase(id);
    }
    return r;
}
}
