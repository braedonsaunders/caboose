// SPDX-License-Identifier: MIT
#include "client.h"
#include <cassert>
#include <cerrno>
#include <cstring>
#include <iostream>
#include <string>
#include <system_error>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace caboose::wsi;
static Bytes id() { Bytes b(40,0); b[0]=1; b[16]=2; b[32]=3; return b; }
static void appendStatus(Bytes& b) { put32(b,0); put32(b,1); put32(b,0); put32(b,0); }
static Bytes recvPacket(int fd, int kind) {
    Bytes b(maxPacket); auto n=recv(fd,b.data(),b.size(),0); assert(n>=16); b.resize(n);
    assert(b[6]==kind && b[7]==0 && u32(b,8)==b.size()); return b;
}
static void sendPacket(int fd, uint16_t kind, const Bytes& body) {
    auto b=packet(kind,body); assert(send(fd,b.data(),b.size(),MSG_NOSIGNAL)==ssize_t(b.size()));
}
// An X11 window bind names its namespace; no other namespace leaves the client.
static void exerciseX11Bind() {
    char dir[]="/tmp/caboose-wsi-test-XXXXXX"; assert(mkdtemp(dir));
    std::string path=std::string(dir)+"/surface";
    int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0); assert(listener>=0);
    sockaddr_un address{}; address.sun_family=AF_UNIX; strcpy(address.sun_path,path.c_str());
    assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
    assert(listen(listener,1)==0);
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        int fd=accept(listener,nullptr,nullptr); assert(fd>=0); close(listener);
        auto bind=recvPacket(fd,16);
        assert(bind.size()==40 && u32(bind,24)==0x400003 && u32(bind,36)==Client::X11Window);
        Bytes bound; put64(bound,9); auto ident=id(); bound.insert(bound.end(),ident.begin(),ident.end()); appendStatus(bound);
        sendPacket(fd,17,bound);
        close(fd); _exit(0);
    }
    close(listener);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    Client client; client.connect(path.c_str(),deadline);
    bool unknownRejected=false;
    try { client.bind(7,0x400003,0,0,deadline,static_cast<Client::Space>(2)); }
    catch (const ProtocolError&) { unknownRejected=true; }
    assert(unknownRejected);
    assert(status(client.bind(7,0x400003,0,0,deadline,Client::X11Window).body,48).success());
    int code=0; assert(waitpid(child,&code,0)==child && WIFEXITED(code) && WEXITSTATUS(code)==0);
    unlink(path.c_str()); rmdir(dir);
}

// A bind the broker refuses ends its connection: that is not executor loss, and after
// reset() the same client binds on a new connection once the window exists.
static int peerGoneCalls=0;
static void exerciseRefusedBind() {
    char dir[]="/tmp/caboose-wsi-test-XXXXXX"; assert(mkdtemp(dir));
    std::string path=std::string(dir)+"/surface";
    int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0); assert(listener>=0);
    sockaddr_un address{}; address.sun_family=AF_UNIX; strcpy(address.sun_path,path.c_str());
    assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
    assert(listen(listener,2)==0);
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        int refused=accept(listener,nullptr,nullptr); assert(refused>=0);
        recvPacket(refused,16); close(refused);
        int fd=accept(listener,nullptr,nullptr); assert(fd>=0); close(listener);
        recvPacket(fd,16);
        usleep(200000); // the reply arrives after the client stopped waiting once
        Bytes bound; put64(bound,9); auto ident=id(); bound.insert(bound.end(),ident.begin(),ident.end()); appendStatus(bound);
        sendPacket(fd,17,bound);
        auto query=recvPacket(fd,18); assert(u64(query,16)==1 && u64(query,24)==11);
        auto caps=id(); put64(caps,1); appendStatus(caps);
        const uint32_t words[]={2,4,640,480,1,1,4096,4096,1,1,1,1,2,1,1,1,44,0,2,0,7,1,1};
        for (auto value:words) put32(caps,value);
        sendPacket(fd,19,caps);
        recvPacket(fd,23); close(fd); _exit(0);
    }
    close(listener);
    Client::peerGone=[] { ++peerGoneCalls; };
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    Client client; client.connect(path.c_str(),deadline);
    bool refused=false;
    try { client.bind(7,13,0,0,deadline); } catch (const std::system_error& e) { refused=e.code().value()==ECONNRESET; }
    assert(refused && !client.bound() && peerGoneCalls==0);
    client.reset();
    client.connect(path.c_str(),deadline);
    // A bind's reply not there yet leaves the bind outstanding; a later wait collects it.
    client.beginBind(7,13,0,0,deadline);
    Record bindReply;
    assert(!client.awaitBind(std::chrono::steady_clock::now()+std::chrono::milliseconds(20),&bindReply));
    assert(client.bindPending() && !client.bound());
    assert(client.awaitBind(deadline,&bindReply) && status(bindReply.body,48).success() && client.bound());
    // A query sent without waiting is kept when it arrives and taken once.
    client.beginQuery(1,11,deadline);
    Record reply;
    assert(client.queryPending() && !client.takeQuery(&reply));
    while (!client.takeQuery(&reply)) { client.pump(); usleep(1000); }
    assert(!client.queryPending() && providerCaps(reply.body).values[2]==640);
    bool reset=false;
    try { client.reset(); } catch (const ProtocolError&) { reset=true; }
    assert(reset); // a bound connection is retired, never reset
    bool lost=false;
    try { client.retire(deadline); } catch (const std::system_error&) { lost=true; }
    assert(lost && peerGoneCalls==1); // a bound connection's end is reported
    Client::peerGone=nullptr;
    int code=0; assert(waitpid(child,&code,0)==child && WIFEXITED(code) && WEXITSTATUS(code)==0);
    unlink(path.c_str()); rmdir(dir);
}

static void exercise(int scenario) {
    char dir[]="/tmp/caboose-wsi-test-XXXXXX"; assert(mkdtemp(dir));
    std::string path=std::string(dir)+"/surface";
    int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0); assert(listener>=0);
    sockaddr_un address{}; address.sun_family=AF_UNIX; strcpy(address.sun_path,path.c_str());
    assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
    assert(listen(listener,1)==0);
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        int fd=accept(listener,nullptr,nullptr); assert(fd>=0); close(listener);
        auto bind=recvPacket(fd,16); assert(bind.size()==40 && u64(bind,16)==7 && u32(bind,24)==13);
        assert(u32(bind,28)==0 && u32(bind,32)==0 && u32(bind,36)==Client::WaylandSurface);
        Bytes bound; put64(bound,9); auto ident=id(); bound.insert(bound.end(),ident.begin(),ident.end()); appendStatus(bound);
        sendPacket(fd,17,bound);
        recvPacket(fd,18);
        auto caps=id(); put64(caps,1); appendStatus(caps);
        const uint32_t words[]={2,4,640,480,1,1,4096,4096,1,1,1,1,2,1,1,1,44,0,2,0,7,1,1};
        for (auto value:words) put32(caps,value);
        sendPacket(fd,19,caps);
        auto present=recvPacket(fd,20); assert(present.size()==88 && u64(present,72)==17 && u64(present,80)==19);
        auto release=id(); put64(release,4);
        auto result=id(); put64(result,4); appendStatus(result); put32(result,1); put32(result,0);
        if (scenario==1) sendPacket(fd,22,release); // legal completion before submission callback
        if (scenario==2) { result[0]=2; sendPacket(fd,21,result); }
        else if (scenario==3) { result.push_back(0); sendPacket(fd,21,result); }
        else if (scenario==4) { close(fd); _exit(0); }
        else {
            sendPacket(fd,21,result);
            if (scenario==0) sendPacket(fd,22,release);
            recvPacket(fd,23);
            if (scenario==5) sendPacket(fd,22,release);
            auto retired=id(); appendStatus(retired); sendPacket(fd,24,retired);
        }
        close(fd); _exit(0);
    }
    close(listener);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    Client client; client.connect(path.c_str(),deadline);
    bool mixedRejected=false;
    try { client.bind(7,13,0,480,deadline); } catch (const ProtocolError&) { mixedRejected=true; }
    assert(mixedRejected);
    assert(status(client.bind(7,13,0,0,deadline).body,48).success());
    auto queried=client.query(1,11,deadline).body;
    const auto caps=providerCaps(queried);
    const std::array<uint32_t,13> expectedCaps={2,4,640,480,1,1,4096,4096,1,1,1,1,2};
    assert(caps.values==expectedCaps);
    assert((caps.formats==std::vector<std::array<uint32_t,2>>{{44,0}}));
    // Deeper and HDR formats the provider lists are not offered: the phone cannot create them.
    ProviderCaps listed=caps;
    listed.formats={{64,0},{44,0},{97,1000104002},{50,0},{37,0},{43,0}};
    assert((presentableFormats(listed)==std::vector<std::array<uint32_t,2>>{{44,0},{50,0},{37,0},{43,0}}));
    assert(caps.modes==std::vector<uint32_t>{2});
    assert((caps.queues==std::vector<std::array<uint32_t,4>>{{0,7,1,1}}));
    auto failedCaps=queried;
    failedCaps.resize(64); failedCaps[56]=0xfc; failedCaps[57]=failedCaps[58]=failedCaps[59]=0xff;
    bool failureRejected=false;
    try { providerCaps(failedCaps); } catch (const ProtocolError&) { failureRejected=true; }
    assert(failureRejected);
    Bytes present; for (auto v:{4,11,13,15}) put64(present,v);
    for (auto v:{44,640,480,1,0,2}) put32(present,v);
    put64(present,17); put64(present,19);
    bool failed=false;
    try {
        auto result=client.present(present,deadline); assert(status(result.body,48).success());
        if (scenario==0) assert(!client.released(4)); // RESULT is not release
        if (scenario==5) {
            bool timedOut=false;
            try { client.waitAnyReleased(std::chrono::steady_clock::now()); }
            catch (const std::system_error& e) { assert(e.code().value()==ETIMEDOUT); timedOut=true; }
            assert(timedOut && !client.released(4) && !client.retired());
            client.retire(deadline); // timeout did not destroy the connection
            assert(client.released(4) && client.retired());
            client.consumeRelease(4);
        } else {
            client.waitReleased(4,deadline); assert(client.released(4));
            client.consumeRelease(4); assert(!client.released(4));
            assert(!client.retired()); client.retire(deadline); assert(client.retired());
        }
    } catch (const std::system_error&) { failed=true; }
    assert(failed==(scenario>=2 && scenario<=4));
    if (failed) assert(!client.retired());
    int result; assert(waitpid(child,&result,0)==child && WIFEXITED(result) && !WEXITSTATUS(result));
    assert(unlink(path.c_str())==0); assert(rmdir(dir)==0);
}
// A probe (no frame to show) carries the probe flag; the compositor refuses it, which ends
// its connection like any refused bind. The next bind with a frame goes out at once, without
// the probe flag (the original form), and is granted.
static void exerciseProbeRefusedThenPresentGranted() {
    using Policy=Client::BindPolicy;
    assert(Policy::probe(false,false,true));
    assert(!Policy::probe(true,false,true) && !Policy::probe(false,true,true));
    assert(!Policy::probe(false,false,false));  // without local answers a query needs the bind
    char dir[]="/tmp/caboose-wsi-test-XXXXXX"; assert(mkdtemp(dir));
    std::string path=std::string(dir)+"/surface";
    int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0); assert(listener>=0);
    sockaddr_un address{}; address.sun_family=AF_UNIX; strcpy(address.sun_path,path.c_str());
    assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
    assert(listen(listener,2)==0);
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        int probe=accept(listener,nullptr,nullptr); assert(probe>=0);
        auto first=recvPacket(probe,16);
        assert(first.size()==48 && u32(first,36)==Client::X11Window && u32(first,40)==1 && u32(first,44)==0);
        close(probe);  // refused
        int fd=accept(listener,nullptr,nullptr); assert(fd>=0); close(listener);
        auto second=recvPacket(fd,16);
        assert(second.size()==40 && u32(second,24)==0x400003);  // a bind with a frame: no flags
        Bytes bound; put64(bound,9); auto ident=id(); bound.insert(bound.end(),ident.begin(),ident.end()); appendStatus(bound);
        sendPacket(fd,17,bound);
        close(fd); _exit(0);
    }
    close(listener);
    auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    Client client; client.connect(path.c_str(),deadline);
    client.beginBind(7,0x400003,0,0,deadline,Client::X11Window,true);
    assert(client.lastBindProbe());
    bool refused=false;
    Record reply;
    try { client.awaitBind(deadline,&reply); } catch (const std::system_error&) { refused=true; }
    assert(refused && !client.bound());
    client.reset();
    // As tryBind does after a refusal: queries wait out the retry delay, a frame does not.
    const auto now=std::chrono::steady_clock::now(), nextBind=now+std::chrono::milliseconds(100);
    assert(!Policy::mayBind(false,now,nextBind,now));
    assert(Policy::mayBind(true,now,nextBind,now));
    assert(!Policy::mayBind(true,now,nextBind,now+std::chrono::seconds(1)));  // a phone failure's backoff holds
    // Refusals in a row space queries out: 100 ms, doubling to at most 1 s.
    assert(Policy::refusedDelay(1)==std::chrono::milliseconds(100));
    assert(Policy::refusedDelay(2)==std::chrono::milliseconds(200));
    assert(Policy::refusedDelay(4)==std::chrono::milliseconds(800));
    assert(Policy::refusedDelay(5)==std::chrono::milliseconds(1000));
    assert(Policy::refusedDelay(1000)==std::chrono::milliseconds(1000));
    {
        const auto later=now+Policy::refusedDelay(6);
        assert(!Policy::mayBind(false,now+std::chrono::milliseconds(999),later,now));
        assert(Policy::mayBind(true,now+std::chrono::milliseconds(999),later,now));  // a frame binds at once
    }
    client.connect(path.c_str(),deadline);
    client.beginBind(7,0x400003,0,0,deadline,Client::X11Window,false);
    assert(!client.lastBindProbe());
    assert(client.awaitBind(deadline,&reply) && status(reply.body,48).success() && client.bound());
    int code=0; assert(waitpid(child,&code,0)==child && WIFEXITED(code) && WEXITSTATUS(code)==0);
    unlink(path.c_str()); rmdir(dir);
}

int main(int argc, char**) {
    if (argc>1) {
        std::string hex;
        while (std::cin>>hex) {
            Bytes bytes;
            for (size_t i=0;i<hex.size();i+=2) bytes.push_back(std::stoul(hex.substr(i,2),nullptr,16));
            try { auto r=decode(bytes); std::cout<<r.kind<<'\n'; }
            catch (const ProtocolError&) { std::cout<<"reject\n"; }
        }
        return 0;
    }
    for (int scenario=0;scenario<6;++scenario) exercise(scenario);
    std::cout<<"6 seqpacket lifecycle scenarios passed\n";
    exerciseX11Bind();
    std::cout<<"X11 window bind passed\n";
    exerciseRefusedBind();
    std::cout<<"refused bind and rebind passed\n";
    exerciseProbeRefusedThenPresentGranted();
    std::cout<<"probe refused, then a frame's bind granted, passed\n";
}
