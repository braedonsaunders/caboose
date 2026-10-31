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
#include <poll.h>
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
            if (frame==1) {
                pollfd pending{fd,POLLIN,0};
                // SOURCE_RELEASED alone must not let the next request through.
                assert(poll(&pending,1,10)==0);
            }
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
        client.waitPresentationIdle(deadline);
    }
    if (scenario==4) assert(invalidIndexRejected && !client.retired());
    else if (scenario!=3) { client.retireSwapchain(111,deadline); client.retire(deadline); assert(client.retired()); }
    int result; assert(waitpid(child,&result,0)==child && WIFEXITED(result) && !WEXITSTATUS(result));
    assert(unlink(path.c_str())==0); assert(rmdir(dir)==0);
}
// Ordered presents (kind 39): the client never waits for PRESENT_RESULT. Results arrive
// while it waits for something else, or are pumped; a refusal ends the swapchain and is
// reported by presentFailed, a rejected frame's image counts as released, and an
// uncertain frame never holds up presentation idle.
// scenario 0: queued, 1: rejected, 2: uncertain, 3: result for a frame never presented,
// 4: two frames in flight; room for a third opens when the oldest retires,
// 5: an acquire made ahead of time: its reply is awaited without being consumed, and a
//    deadline before it arrives leaves the connection and the acquire intact,
// 6: records already waiting when pump runs are applied without blocking or failing.
static void exerciseOrdered(int scenario) {
    char dir[]="/tmp/caboose-ordered-test-XXXXXX"; assert(mkdtemp(dir));
    std::string path=std::string(dir)+"/surface";
    int listener=socket(AF_UNIX,SOCK_SEQPACKET|SOCK_CLOEXEC,0); assert(listener>=0);
    sockaddr_un address{}; address.sun_family=AF_UNIX; strcpy(address.sun_path,path.c_str());
    assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);
    assert(listen(listener,1)==0);
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        int fd=accept(listener,nullptr,nullptr); assert(fd>=0); close(listener);
        receive(fd,16); Bytes bound; put64(bound,9); auto ident=identityBytes();
        bound.insert(bound.end(),ident.begin(),ident.end()); statusBytes(bound); transmit(fd,17,bound);
        receive(fd,25);
        auto created=identityBytes(); put64(created,1); put64(created,111); statusBytes(created);
        put32(created,2); put32(created,0); transmit(fd,26,created);
        receive(fd,27); auto mapped=identityBytes(); put64(mapped,111); statusBytes(mapped); transmit(fd,28,mapped);
        auto sendAcquired=[&](uint64_t request, uint32_t index) {
            auto acquired=identityBytes(); put64(acquired,111); put64(acquired,request); statusBytes(acquired);
            put32(acquired,1); put32(acquired,index); put32(acquired,0); put32(acquired,0); transmit(fd,30,acquired);
        };
        receive(fd,29); sendAcquired(2,0);
        if (scenario==6) {
            receive(fd,39);
            auto result=identityBytes(); put64(result,1); statusBytes(result); put32(result,2); put32(result,0);
            transmit(fd,21,result);
            receive(fd,23); auto retired=identityBytes(); statusBytes(retired); transmit(fd,24,retired);
            close(fd); _exit(0);
        }
        if (scenario==5) {
            receive(fd,39);
            receive(fd,29);
            pollfd quiet{fd,POLLIN,0}; assert(poll(&quiet,1,100)==0);  // the client keeps waiting quietly
            sendAcquired(3,1);
            receive(fd,23); auto retired=identityBytes(); statusBytes(retired); transmit(fd,24,retired);
            close(fd); _exit(0);
        }
        if (scenario==4) {
            receive(fd,39); receive(fd,29); sendAcquired(3,1); receive(fd,39);
            for (uint64_t frame:{1,2}) {
                auto result=identityBytes(); put64(result,frame); statusBytes(result); put32(result,1); put32(result,0);
                transmit(fd,21,result);
                auto released=identityBytes(); put64(released,frame); transmit(fd,22,released);
            }
            auto first=identityBytes(); put64(first,111); put64(first,1); transmit(fd,36,first);
            pollfd quiet{fd,POLLIN,0}; assert(poll(&quiet,1,50)==0);  // the client has room now
            auto second=identityBytes(); put64(second,111); put64(second,2); transmit(fd,36,second);
            receive(fd,23); auto retired=identityBytes(); statusBytes(retired); transmit(fd,24,retired);
            close(fd); _exit(0);
        }
        auto present=receive(fd,39);
        assert(present.size()==80 && u64(present,16)==111 && u64(present,24)==1 && u64(present,32)==13);
        assert(u64(present,40)==77 && u32(present,48)==0 && u32(present,56)==1 && u32(present,60)==2);
        if (scenario==3) {
            auto stray=identityBytes(); put64(stray,5); statusBytes(stray); put32(stray,1); put32(stray,0);
            transmit(fd,21,stray); receive(fd,29); close(fd); _exit(0);
        }
        // The result arrives only after the client moved on to its next acquire.
        receive(fd,29);
        auto result=identityBytes(); put64(result,1);
        if (scenario==1) statusBytes(result,ESTALE,0,0); else statusBytes(result,0,1,0);
        put32(result,scenario==0 ? 1 : scenario==1 ? 0 : 2); put32(result,0); transmit(fd,21,result);
        if (scenario==0) {
            auto released=identityBytes(); put64(released,1); transmit(fd,22,released);
            auto final=identityBytes(); put64(final,111); put64(final,1); transmit(fd,36,final);
        }
        sendAcquired(3,1);
        if (scenario==0) {
            receive(fd,39);
            auto second=identityBytes(); put64(second,2); statusBytes(second); put32(second,1); put32(second,0);
            transmit(fd,21,second);
            auto released=identityBytes(); put64(released,2); transmit(fd,22,released);
            auto final=identityBytes(); put64(final,111); put64(final,2); transmit(fd,36,final);
            receive(fd,32); auto retiredSwap=identityBytes(); put64(retiredSwap,111); statusBytes(retiredSwap);
            transmit(fd,33,retiredSwap);
        }
        receive(fd,23); auto retired=identityBytes(); statusBytes(retired); transmit(fd,24,retired);
        close(fd); _exit(0);
    }
    close(listener); auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);
    Client client; client.connect(path.c_str(),deadline); client.bind(7,13,0,0,deadline);
    Bytes create; put64(create,1); put64(create,11); put64(create,0);
    for (uint32_t word:{0,2,44,0,640,480,1,18,1,1,2,1,0,0}) put32(create,word);
    client.createSwapchain(create,deadline);
    client.mapSwapchain(111,{101,103},deadline);
    client.beginAcquire(111,2,17,0,12345,deadline);
    assert(u32(client.finishAcquire(111,2,deadline).body,76)==0);
    client.presentOrdered(111,1,13,77,0,0,{19,23},deadline);
    Status failure{};
    assert(!client.presentFailed(111,&failure));
    if (scenario==6) {
        usleep(100000);  // the uncertain result is already waiting
        client.pump();
        assert(client.presentFailed(111,&failure) && failure.nativeError==EIO);
        client.pump();   // nothing waiting: returns at once
        client.retire(deadline); assert(client.retired());
    } else if (scenario==5) {
        client.beginAcquire(111,3,17,0,UINT64_MAX,deadline);
        assert(!client.awaitAcquireReply(111,std::chrono::steady_clock::now()+std::chrono::milliseconds(30)));
        assert(client.awaitAcquireReply(111,deadline));
        assert(client.awaitAcquireReply(111,deadline));  // not consumed
        auto reply=client.finishAcquire(111,3,deadline);
        assert(u64(reply.body,48)==3 && u32(reply.body,76)==1);
        client.retire(deadline); assert(client.retired());
    } else if (scenario==4) {
        client.waitPresentationRoom(2,deadline);  // one frame in flight: no wait
        client.beginAcquire(111,3,17,0,12345,deadline);
        assert(u32(client.finishAcquire(111,3,deadline).body,76)==1);
        client.presentOrdered(111,2,13,78,1,0,{19,23},deadline);
        client.waitPresentationRoom(2,deadline);  // returns once frame 1 retires
        client.waitPresentationIdle(deadline);    // returns once frame 2 retires
        client.retire(deadline); assert(client.retired());
    } else if (scenario==3) {
        bool rejected=false;
        try { client.beginAcquire(111,3,17,0,12345,deadline); client.pump();
              client.finishAcquire(111,3,deadline); }
        catch (const std::system_error& error) { rejected=error.code().value()==EPROTO; }
        assert(rejected);
    } else {
        client.beginAcquire(111,3,17,0,12345,deadline);
        assert(u32(client.finishAcquire(111,3,deadline).body,76)==1);
        if (scenario==0) {
            assert(!client.presentFailed(111,&failure));
            client.waitReleased(1,deadline); client.consumeRelease(1);
            client.waitPresentationIdle(deadline);
            client.presentOrdered(111,2,13,78,1,0,{19,23},deadline);
            client.waitPresentationIdle(deadline);
            client.pump();
            assert(!client.presentFailed(111,&failure));
            client.retireSwapchain(111,deadline);
        } else {
            assert(client.presentFailed(111,&failure));
            assert(scenario==1 ? failure.nativeError==ESTALE : failure.nativeError==EIO);
            // An uncertain frame never retires, so idle must not wait for it.
            client.waitPresentationIdle(deadline);
            if (scenario==1) { assert(client.released(1)); client.consumeRelease(1); assert(!client.released(1)); }
            bool refused=false;
            try { client.presentOrdered(111,2,13,78,1,0,{19,23},deadline); }
            catch (const ProtocolError&) { refused=true; }
            assert(refused);
        }
        client.retire(deadline); assert(client.retired());
    }
    int result; assert(waitpid(child,&result,0)==child && WIFEXITED(result) && !WEXITSTATUS(result));
    assert(unlink(path.c_str())==0); assert(rmdir(dir)==0);
}
int main() {
    for (int scenario=0;scenario<5;++scenario) exercise(scenario);
    for (int scenario=0;scenario<7;++scenario) exerciseOrdered(scenario);
    std::cout<<"5 indexed and 7 ordered-present scenarios passed, including 130 frames with final retirement\n";
}
