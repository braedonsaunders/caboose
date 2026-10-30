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
static Bytes identityBytes() { Bytes b(40,0); b[0]=1; b[16]=2; b[32]=3; return b; }
static void statusBytes(Bytes& b, uint32_t error=0, uint32_t has=1, uint32_t vk=0) {
    put32(b,error); put32(b,has); put32(b,vk); put32(b,0);
}
static Bytes receive(int fd, int kind) {
    Bytes b(maxPacket); auto n=recv(fd,b.data(),b.size(),0); assert(n>=16); b.resize(n);
    assert(b[6]==kind && b[7]==0 && u32(b,8)==b.size()); return b;
}
static void transmit(int fd, uint16_t kind, const Bytes& body) {
    auto b=packet(kind,body); assert(send(fd,b.data(),b.size(),MSG_NOSIGNAL)==ssize_t(b.size()));
}
static void exercise(int scenario) {
    char dir[]="/tmp/caboose-indexed-test-XXXXXX"; assert(mkdtemp(dir));
    std::string path=std::string(dir)+"/surface";
    int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0); assert(listener>=0);
    sockaddr_un address{}; address.sun_family=AF_UNIX; strcpy(address.sun_path,path.c_str());
    assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
    assert(listen(listener,1)==0);
    const int frames=scenario==0 ? 130 : 1;
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        int fd=accept(listener,nullptr,nullptr); assert(fd>=0); close(listener);
        receive(fd,16); Bytes bound; put64(bound,9); auto ident=identityBytes();
        bound.insert(bound.end(),ident.begin(),ident.end()); statusBytes(bound); transmit(fd,17,bound);
        auto create=receive(fd,25); assert(create.size()==96 && u32(create,44)==2 && u32(create,92)==0);
        auto created=identityBytes(); put64(created,1); put64(created,111); statusBytes(created);
        put32(created,2); put32(created,0); transmit(fd,26,created);
        auto map=receive(fd,27); assert(map.size()==48 && u32(map,24)==2 && u64(map,32)==101 && u64(map,40)==103);
        auto mapped=identityBytes(); put64(mapped,111); statusBytes(mapped); transmit(fd,28,mapped);
        for (int frame=1;frame<=frames;++frame) {
            auto acquire=receive(fd,29); assert(u64(acquire,24)==uint64_t(frame+1));
            assert(u64(acquire,32)==17 && u64(acquire,40)==0 && u32(acquire,56)==1);
            if (scenario==1) { auto cancel=receive(fd,31); assert(u64(cancel,24)==2); }
            if (scenario==3) transmit(fd,35,identityBytes());
            auto acquired=identityBytes(); put64(acquired,111); put64(acquired,frame+1);
            statusBytes(acquired,scenario==2 ? 60 : 0,scenario==2 ? 0 : 1);
            put32(acquired,scenario==2 ? 0 : 1); put32(acquired,scenario==4 ? 2 : uint32_t((frame-1)%2));
            put32(acquired,scenario==2 ? 1 : 0); put32(acquired,0); transmit(fd,30,acquired);
            if (scenario==4) { close(fd); _exit(0); }
            if (scenario==3) {
                auto retired=identityBytes(); statusBytes(retired); transmit(fd,24,retired); close(fd); _exit(0);
            }
            if (scenario==2) break;
            auto present=receive(fd,34);
            assert(present.size()==72 && u64(present,16)==111 && u64(present,24)==uint64_t(frame));
            assert(u32(present,48)==1 && u32(present,52)==2 && u64(present,56)==19 && u64(present,64)==23);
            auto result=identityBytes(); put64(result,frame); statusBytes(result); put32(result,1); put32(result,0);
            transmit(fd,21,result);
            auto released=identityBytes(); put64(released,frame); transmit(fd,22,released);
            auto final=identityBytes(); put64(final,111); put64(final,frame); transmit(fd,36,final);
        }
        receive(fd,32); auto retiredSwap=identityBytes(); put64(retiredSwap,111); statusBytes(retiredSwap); transmit(fd,33,retiredSwap);
        receive(fd,23); auto retired=identityBytes(); statusBytes(retired); transmit(fd,24,retired);
        close(fd); _exit(0);
    }
    close(listener); auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    Client client; client.connect(path.c_str(),deadline); client.bind(7,13,0,0,deadline);
    Bytes create; put64(create,1); put64(create,11); put64(create,0);
    for (uint32_t word:{0,2,44,0,640,480,1,18,1,1,2,1,0,0}) put32(create,word);
    auto created=client.createSwapchain(create,deadline); assert(u64(created.body,48)==111 && u32(created.body,72)==2);
    client.mapSwapchain(111,{101,103},deadline);
    bool invalidIndexRejected=false;
    for (int frame=1;frame<=frames;++frame) {
        client.beginAcquire(111,frame+1,17,0,12345,deadline);
        if (scenario==1) client.cancelAcquire(111,2,deadline);
        Record acquired;
        try { acquired=client.finishAcquire(111,frame+1,deadline); }
        catch (const std::system_error&) { assert(scenario==4); invalidIndexRejected=true; break; }
        if (scenario==2) {
            auto s=status(acquired.body,56); assert(s.nativeError==60 && !s.hasVk && u32(acquired.body,80)==1);
            break; // retain Apple errno + explicit reason, never reinterpret as Linux timeout
        }
        assert(u32(acquired.body,72)==1 && u32(acquired.body,76)==uint32_t((frame-1)%2));
        if (scenario==3) { assert(client.revoked()); client.retire(deadline); assert(client.retired()); break; }
        if (scenario==1) client.cancelAcquire(111,2,deadline); // completed cancel emits no duplicate
        client.presentIndexed(111,frame,13,(frame-1)%2,0,{19,23},deadline);
        client.waitReleased(frame,deadline); client.consumeRelease(frame); assert(!client.released(frame));
    }
    if (scenario==4) assert(invalidIndexRejected && !client.retired());
    else if (scenario!=3) { client.retireSwapchain(111,deadline); client.retire(deadline); assert(client.retired()); }
    int result; assert(waitpid(child,&result,0)==child && WIFEXITED(result) && !WEXITSTATUS(result));
    assert(unlink(path.c_str())==0); assert(rmdir(dir)==0);
}
int main() {
    for (int scenario=0;scenario<5;++scenario) exercise(scenario);
    std::cout<<"5 indexed scenarios passed, including 130 frames with final retirement\n";
}
