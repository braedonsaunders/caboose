// SPDX-License-Identifier: MIT
#include "flush_window.h"
#include <cassert>
#include <stdexcept>
#include <vector>
using namespace caboose::memory;
int main() {
    // Every provider-error position drains the whole sent window, preserving the
    // earliest result and admitting no subsequent window.
    for (int fail = 0; fail < 8; ++fail) {
        int sent=0, read=0, invalid=0;
        FlushWindow w{[&](unsigned, unsigned long long, unsigned long long) { ++sent; return 0; },
            [&](int& result) { result = read++ == fail ? -1 : read==8 ? -2 : 0; return true; },
            [&] { ++invalid; }};
        for(int i=0;i<7;++i) assert(w.push(0,i,1)==0 && read==0);
        assert(w.push(0,7,1)==-1 && read==8 && sent==8 && invalid==0);
        assert(w.push(0,8,1)==-1 && sent==8);
        assert(w.finish()==-1);
    }
    // Transport failure outranks any earlier provider failure; no reply reuse.
    for(int fail=0;fail<8;++fail) {
        int sent=0,read=0,invalid=0;
        FlushWindow w{[&](unsigned,unsigned long long,unsigned long long){++sent;return 0;},
            [&](int& result){result=-1;return read++ != fail;},[&]{++invalid;}};
        for(int i=0;i<7;++i)assert(w.push(0,i,1)==0);
        assert(w.push(0,7,1)==-4 && invalid==1 && read==fail+1);
        assert(w.finish()==-4 && w.push(0,8,1)==-4 && sent==8);
    }
    // Failed or throwing sends may have emitted partial bytes. Always poison
    // the stream, including when earlier complete packets await replies.
    for(int fail=0;fail<8;++fail) for(bool throws:{false,true}) {
        int sent=0,read=0,invalid=0;
        FlushWindow w{[&](unsigned,unsigned long long,unsigned long long){
                if(sent++==fail){if(throws)throw std::runtime_error("partial send");return -4;}return 0;},
            [&](int& result){++read;result=0;return true;},[&]{++invalid;}};
        for(int i=0;i<fail;++i)assert(w.push(0,i,1)==0);
        try { assert(w.push(0,fail,1)==-4 && !throws); }
        catch(const std::runtime_error&){assert(throws);}
        assert(invalid==1 && read==0 && w.finish()==-4);
    }
    // The same 513 packets used by a 32 MiB atom-aligned flush are drained in
    // order, eight at a time, with the final partial window fully consumed.
    int sent=0,read=0,invalid=0,windows=0;
    FlushWindow w{[&](unsigned i,unsigned long long offset,unsigned long long size){
            assert(i==0 && offset==static_cast<unsigned>(sent) && size==1);++sent;return 0;},
        [&](int& result){assert(read<sent && sent-read<=8);if(read%8==0)++windows;++read;result=0;return true;},
        [&]{++invalid;}};
    for(int i=0;i<513;++i)assert(w.push(0,i,1)==0);
    assert(sent==513 && read==512 && w.finish()==0 && read==513 && windows==65 && invalid==0);
    // Abandonment never permits outstanding replies to contaminate later RPCs.
    { FlushWindow abandoned{[](unsigned,unsigned long long,unsigned long long){return 0;},
        [](int&){return true;},[&]{++invalid;}};assert(abandoned.push(0,0,1)==0); }
    assert(invalid==1);
}
