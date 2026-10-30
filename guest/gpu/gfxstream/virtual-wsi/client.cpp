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
    for (;;) {
        auto r=receive(deadline);
        if (r.kind==0x7fff) fail(status(r.body,0).nativeError);
        if (bound_ && identity(r.body,r.kind==17?8:0)!=identity_) fail(EPROTO);
        if (r.kind==22) {
            auto it=sources_.find(u64(r.body,40));
            if (it==sources_.end() || it->second.released) fail(EPROTO);
            it->second.released=true;
            if (kind==22 && (!serial || u64(r.body,40)==serial)) return r;
            continue;
        }
        if (r.kind!=kind || (serial && u64(r.body,40)!=serial)) fail(EPROTO);
        return r;
    }
}
Record Client::bind(uint64_t instance, uint32_t object, uint32_t width, uint32_t height, Deadline deadline) {
    require(!bound_ && instance && object && bool(width)==bool(height));
    Bytes p; put64(p,instance); put32(p,object); put32(p,width); put32(p,height); put32(p,0);
    send(16,p,deadline); auto r=await(17,0,deadline);
    if (status(r.body,48).success()) { identity_=identity(r.body,8); bound_=true; }
    return r;
}
Record Client::query(uint64_t request, uint64_t physical, Deadline deadline) {
    require(bound_ && !retiring_ && request>lastQuery_ && physical);
    lastQuery_=request;
    Bytes p; put64(p,request); put64(p,physical); send(18,p,deadline);
    return await(19,request,deadline);
}
Record Client::present(const Bytes& p, Deadline deadline) {
    require(bound_ && !retiring_ && p.size()>=56);
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
    auto it=sources_.find(serial); return it!=sources_.end() && it->second.released;
}
void Client::waitReleased(uint64_t serial, Deadline deadline) {
    require(bound_ && sources_.count(serial));
    releaseWait_=true;
    try { if (!released(serial)) await(22,serial,deadline); }
    catch (...) { releaseWait_=false; throw; }
    releaseWait_=false;
}
uint64_t Client::waitAnyReleased(Deadline deadline) {
    require(bound_ && !sources_.empty());
    for (const auto& item:sources_) if (item.second.released) return item.first;
    releaseWait_=true;
    try {
        auto result=await(22,0,deadline); releaseWait_=false; return u64(result.body,40);
    } catch (...) { releaseWait_=false; throw; }
}
void Client::consumeRelease(uint64_t serial) {
    require(released(serial) && sources_.at(serial).result);
    sources_.erase(serial);
}
Record Client::retire(Deadline deadline) {
    require(bound_ && !retiring_);
    retiring_=true; send(23,{},deadline); auto r=await(24,0,deadline);
    retired_=status(r.body,40).success();
    return r;
}
}
