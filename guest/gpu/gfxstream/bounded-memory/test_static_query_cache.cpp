// SPDX-License-Identifier: MIT
#include "static_query_cache.h"
#include <cassert>
#include <cstdlib>
#include <chrono>
#include <dirent.h>
#include <sys/wait.h>
using caboose::memory::StaticQueryCache;
using Cache=StaticQueryCache;
static std::string file(const std::string& directory,const std::string& identity) {
    char name[40]; std::snprintf(name,sizeof(name),"/formats-%016llx.bin",(unsigned long long)Cache::digest("protocol"+identity));
    return directory+name;
}
static void identify(Cache& cache,uint64_t handle,const std::string& identity,const std::string& directory) {
    cache.connection("protocol",8); cache.identify(handle,identity,directory);
}
int main() {
    Cache cache;
    struct Answer { int32_t result; uint32_t values[4]; };
    const auto a=Cache::key(uint32_t(20004),uint64_t(0x10),uint32_t(44));
    const auto b=Cache::key(uint32_t(20004),uint64_t(0x10),uint32_t(45));
    const auto c=Cache::key(uint32_t(20005),uint64_t(0x10),uint32_t(44));
    assert(a!=b && a!=c);
    Answer out{};
    assert(!cache.lookup(a,&out));
    cache.store(a,Answer{-11,{1,2,3,4}});
    assert(cache.lookup(a,&out) && out.result==-11 && out.values[3]==4);
    assert(!cache.lookup(b,&out));
    uint64_t wrong=0; assert(!cache.lookup(a,&wrong));
    for (uint32_t i=0;i<Cache::kMaxEntries+10;++i) cache.store(Cache::key(uint32_t(1),i),i);
    assert(cache.size()==Cache::kMaxEntries && cache.lookup(a,&out));
    char temporary[]="/tmp/caboose-capabilities-XXXXXX";
    assert(mkdtemp(temporary));
    char* resolved=realpath(temporary,nullptr); assert(resolved);
    const std::string directory=resolved; free(resolved);
    const std::string identity="backend/device/driver/build/features";
    Cache writer; identify(writer,0x10,identity,directory);
    assert(!writer.lookup(a,&out)); writer.store(a,Answer{0,{5,6,7,8}});
    const auto fresh=Cache::key(uint32_t(20004),uint64_t(0x20),uint32_t(44));
    pid_t child=fork(); assert(child>=0);
    if (!child) {
        Cache reader; identify(reader,0x20,identity,directory);
        assert(reader.lookup(fresh,&out) && out.result==0 && out.values[3]==8);
        assert(!reader.lookup(a,&out)); // numeric identities do not leak across processes
        _exit(0);
    }
    int status=0; assert(waitpid(child,&status,0)==child && status==0);
    Cache other; identify(other,0x20,identity+"-other-phone",directory);
    assert(!other.lookup(fresh,&out));
    identify(other,0x20,identity,directory); assert(other.lookup(fresh,&out));
    other.connection("changed-protocol",16); other.identify(0x20,identity,directory);
    assert(!other.lookup(fresh,&out));
    const auto staleEpoch=other.epoch();
    other.reset(); assert(!other.lookup(fresh,&out));
    other.connection("protocol",8);
    other.identify(0x20,identity,directory,staleEpoch);
    assert(!other.lookup(fresh,&out)); // late identity reply cannot join a new session

    // An unsafe seat directory, parent symlink or public file cannot supply answers.
    assert(!chmod(directory.c_str(),0755));
    Cache publicDirectory; identify(publicDirectory,0x20,identity,directory);
    assert(!publicDirectory.lookup(fresh,&out));
    assert(!chmod(directory.c_str(),0700));
    const std::string alias=directory+"-link";
    assert(!symlink(directory.c_str(),alias.c_str()));
    Cache parentLink; identify(parentLink,0x20,identity,alias);
    assert(!parentLink.lookup(fresh,&out)); assert(!unlink(alias.c_str()));
    assert(!chmod(file(directory,identity).c_str(),0644));
    Cache publicFile; identify(publicFile,0x20,identity,directory);
    assert(!publicFile.lookup(fresh,&out));
    assert(!chmod(file(directory,identity).c_str(),0600));
    // Concurrent writers may miss on contention, but every published snapshot must
    // remain complete and preserve prior records. Each child uses a fresh handle.
    pid_t writers[4]{};
    for (uint32_t i=0;i<4;++i) {
        writers[i]=fork(); assert(writers[i]>=0);
        if (!writers[i]) {
            Cache concurrent; identify(concurrent,0x100+i,identity,directory);
            for (uint32_t j=0;j<32;++j)
                concurrent.store(Cache::key(uint32_t(20004),uint64_t(0x100+i),uint32_t(100+i*32+j)),
                                 Answer{0,{i,j,7,8}});
            _exit(0);
        }
    }
    for (pid_t pid:writers) assert(waitpid(pid,&status,0)==pid && status==0);
    Cache afterWriters; identify(afterWriters,0x20,identity,directory);
    assert(afterWriters.lookup(fresh,&out) && out.values[3]==8);
    for (uint32_t i=0;i<4;++i) for (uint32_t j=0;j<32;++j) {
        if (afterWriters.lookup(Cache::key(uint32_t(20004),uint64_t(0x20),uint32_t(100+i*32+j)),&out))
            assert(out.result==0 && out.values[0]==i && out.values[1]==j && out.values[3]==8);
    }
    const std::string path=file(directory,identity);
    int fd=open(path.c_str(),O_RDWR); assert(fd>=0);
    int locked=open((path+".lock").c_str(),O_RDWR); assert(locked>=0);
    assert(!flock(locked,LOCK_EX));
    child=fork(); assert(child>=0);
    if (!child) {
        close(fd); close(locked); Cache locked; identify(locked,0x20,identity,directory);
        assert(!locked.lookup(fresh,&out)); _exit(0);
    }
    assert(waitpid(child,&status,0)==child && status==0);
    assert(!flock(locked,LOCK_UN)); close(locked);
    struct stat before{}; assert(!fstat(fd,&before));
    assert(!ftruncate(fd,Cache::kMaxFileBytes+1));
    Cache oversized; identify(oversized,0x20,identity,directory);
    assert(!oversized.lookup(fresh,&out)); assert(!ftruncate(fd,before.st_size));
    // A torn final record costs only itself: earlier records stay authoritative and the
    // next writer cuts the tail away before appending.
    assert(pwrite(fd,"x",1,before.st_size)==1);
    Cache partial; identify(partial,0x20,identity,directory); assert(partial.lookup(fresh,&out));
    const auto late=Cache::key(uint32_t(20004),uint64_t(0x20),uint32_t(900));
    partial.store(late,Answer{0,{9,9,9,9}});
    Cache repaired; identify(repaired,0x20,identity,directory);
    assert(repaired.lookup(fresh,&out) && repaired.lookup(late,&out) && out.values[0]==9);
    struct stat grown{}; assert(!fstat(fd,&grown) && grown.st_size>before.st_size);
    // A damaged checksum in the last record hides that record only.
    char byte=0; assert(pread(fd,&byte,1,grown.st_size-1)==1); byte^=1;
    assert(pwrite(fd,&byte,1,grown.st_size-1)==1);
    Cache corrupt; identify(corrupt,0x20,identity,directory);
    assert(corrupt.lookup(fresh,&out) && !corrupt.lookup(late,&out));
    // Damage in the first record hides everything after it.
    const size_t headerBytes=8+4+std::string("protocol"+identity).size();
    assert(pread(fd,&byte,1,headerBytes+16)==1); byte^=1; assert(pwrite(fd,&byte,1,headerBytes+16)==1);
    Cache first; identify(first,0x20,identity,directory); assert(!first.lookup(fresh,&out));
    // A file of another format is never read; a writer restarts the log in place.
    assert(pwrite(fd,"\1",1,4)==1);
    Cache older; identify(older,0x20,identity,directory); assert(!older.lookup(fresh,&out));
    older.store(late,Answer{0,{9,9,9,9}});
    Cache restarted; identify(restarted,0x20,identity,directory);
    assert(restarted.lookup(late,&out) && !restarted.lookup(fresh,&out));
    close(fd); assert(!unlink(path.c_str()));
    // Cold discovery appends each record once: bytes written equal the file's records,
    // never a rewrite of what is already there.
    {
        Cache cold; identify(cold,0x30,identity,directory);
        for (uint32_t i=0;i<368;++i) cold.store(Cache::key(uint32_t(20004),uint64_t(0x30),i),Answer{0,{i,1,2,3}});
        struct stat info{}; assert(!stat(path.c_str(),&info));
        assert(cold.writes()==368 && cold.writeBytes()+headerBytes==uint64_t(info.st_size));
        Cache warm; identify(warm,0x31,identity,directory);
        for (uint32_t i=0;i<368;++i)
            assert(warm.lookup(Cache::key(uint32_t(20004),uint64_t(0x31),i),&out) && out.values[0]==i);
        for (uint32_t i=0;i<368;++i) warm.store(Cache::key(uint32_t(20004),uint64_t(0x31),i),Answer{0,{i,1,2,3}});
        assert(warm.writes()==0);
        // A forked child takes its own lock and appends after its parent's records.
        child=fork(); assert(child>=0);
        if (!child) {
            cold.store(Cache::key(uint32_t(20004),uint64_t(0x30),uint32_t(5000)),Answer{0,{50,0,0,0}});
            _exit(cold.writes()==369 ? 0 : 1);
        }
        assert(waitpid(child,&status,0)==child && status==0);
        cold.store(Cache::key(uint32_t(20004),uint64_t(0x30),uint32_t(5001)),Answer{0,{51,0,0,0}});
        Cache both; identify(both,0x32,identity,directory);
        assert(both.lookup(Cache::key(uint32_t(20004),uint64_t(0x32),uint32_t(5000)),&out) && out.values[0]==50);
        assert(both.lookup(Cache::key(uint32_t(20004),uint64_t(0x32),uint32_t(5001)),&out) && out.values[0]==51);
        assert(both.lookup(Cache::key(uint32_t(20004),uint64_t(0x32),uint32_t(367)),&out));
    }
    // Records held back by a busy lock go out with the next append.
    {
        Cache busy; identify(busy,0x40,identity,directory);
        locked=open((path+".lock").c_str(),O_RDWR); assert(locked>=0);
        assert(!flock(locked,LOCK_EX));
        for (uint32_t i=0;i<4;++i) busy.store(Cache::key(uint32_t(20005),uint64_t(0x40),i),Answer{0,{i,4,4,4}});
        assert(busy.writes()==0);
        assert(!flock(locked,LOCK_UN)); close(locked);
        busy.store(Cache::key(uint32_t(20005),uint64_t(0x40),uint32_t(4)),Answer{0,{4,4,4,4}});
        assert(busy.writes()==5);
        Cache later; identify(later,0x41,identity,directory);
        for (uint32_t i=0;i<5;++i)
            assert(later.lookup(Cache::key(uint32_t(20005),uint64_t(0x41),i),&out) && out.values[0]==i);
    }
    // Single flight: a process that misses a question another process has claimed waits
    // for that answer instead of asking again; a lapsed claim stops holding it back, and a
    // process never waits on its own claims.
    {
        const auto shared=[](uint64_t handle){ return Cache::key(uint32_t(30004),handle,uint32_t(77)); };
        int ready[2]; assert(!pipe(ready));
        child=fork(); assert(child>=0);
        if (!child) {
            close(ready[0]);
            Cache asker; identify(asker,0x50,identity,directory);
            Answer none{}; if (asker.lookup(shared(0x50),&none)) _exit(1);
            if (write(ready[1],"c",1)!=1) _exit(3);
            struct timespec pause{0,200000000}; nanosleep(&pause,nullptr);
            asker.store(shared(0x50),Answer{0,{77,0,0,0}});
            _exit(asker.claims()==1 ? 0 : 2);
        }
        close(ready[1]); char signal=0; if (read(ready[0],&signal,1)!=1) { waitpid(child,&status,0); std::fprintf(stderr,"child status %d\n",status); abort(); } close(ready[0]);
        Cache joiner; identify(joiner,0x51,identity,directory);
        const auto before=std::chrono::steady_clock::now();
        assert(joiner.lookup(shared(0x51),&out) && out.values[0]==77);
        const auto waited=std::chrono::steady_clock::now()-before;
        assert(waited>=std::chrono::milliseconds(100) && waited<std::chrono::milliseconds(1500));
        assert(joiner.joined()==1 && joiner.claims()==0);
        assert(waitpid(child,&status,0)==child && status==0);

        child=fork(); assert(child>=0);
        if (!child) {
            Cache quitter; identify(quitter,0x52,identity,directory);
            Answer none{}; _exit(quitter.lookup(Cache::key(uint32_t(30004),uint64_t(0x52),uint32_t(78)),&none) ? 1 : 0);
        }
        assert(waitpid(child,&status,0)==child && status==0);
        Cache after; identify(after,0x53,identity,directory);
        const auto lapsed=std::chrono::steady_clock::now();
        assert(!after.lookup(Cache::key(uint32_t(30004),uint64_t(0x53),uint32_t(78)),&out));
        const auto held=std::chrono::steady_clock::now()-lapsed;
        assert(held>=std::chrono::milliseconds(1500) && held<std::chrono::milliseconds(2600) && after.claims()==1);
        const auto own=std::chrono::steady_clock::now();
        assert(!after.lookup(Cache::key(uint32_t(30004),uint64_t(0x53),uint32_t(78)),&out));
        assert(std::chrono::steady_clock::now()-own<std::chrono::milliseconds(100));
    }
    assert(!unlink(path.c_str()));
    // Symlinked cache files are never read or written.
    assert(!symlink("/dev/null",path.c_str()));
    Cache link; identify(link,0x20,identity,directory); assert(!link.lookup(fresh,&out));
    link.store(fresh,Answer{}); assert(!unlink(path.c_str()));
    DIR* contents=opendir(directory.c_str()); assert(contents);
    while (auto* entry=readdir(contents)) {
        if (entry->d_name[0]=='.') continue;
        assert(!unlinkat(dirfd(contents),entry->d_name,0));
    }
    closedir(contents); assert(!rmdir(directory.c_str()));
    std::puts("static capabilities: exact keys, process reuse, identity/protocol isolation, bounds, locks, append-only writes, single flight and corruption passed");
}
