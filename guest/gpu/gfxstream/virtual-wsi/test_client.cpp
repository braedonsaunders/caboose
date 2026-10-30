// SPDX-License-Identifier: MIT
#include "client.h"
#include <cassert>
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
        assert(u32(bind,28)==0 && u32(bind,32)==0);
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
    assert(client.query(1,11,deadline).body.size()==156);
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
}
