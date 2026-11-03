// SPDX-License-Identifier: MIT
#include "static_query_cache.h"
#include <cassert>
#include <cstdlib>
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
    // Partial append or corrupted checksum makes the whole file non-authoritative.
    assert(pwrite(fd,"x",1,before.st_size)==1);
    Cache partial; identify(partial,0x20,identity,directory); assert(!partial.lookup(fresh,&out));
    assert(!ftruncate(fd,before.st_size));
    char byte=0; assert(pread(fd,&byte,1,before.st_size-1)==1); byte^=1;
    assert(pwrite(fd,&byte,1,before.st_size-1)==1);
    Cache corrupt; identify(corrupt,0x20,identity,directory); assert(!corrupt.lookup(fresh,&out));
    close(fd); assert(!unlink(path.c_str()));
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
    std::puts("static capabilities: exact keys, process reuse, identity/protocol isolation, bounds, locks and corruption passed");
}
