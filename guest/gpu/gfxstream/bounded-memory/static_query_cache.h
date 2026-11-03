// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <fcntl.h>
#include <mutex>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace caboose::memory {
// Exact, immutable physical-device answers. Unsupported query chains bypass this cache
// at the call site. A persistent scope includes backend, device/driver and guest build
// identity; without a verified scope answers remain process-local.
class StaticQueryCache {
public:
    ~StaticQueryCache() {
        // One last nonblocking attempt for records a busy lock held back. Exit never
        // waits: a mutex another thread (or a forking parent) holds skips it.
        std::unique_lock<std::mutex> lock(mutex_,std::try_to_lock);
        if (!lock.owns_lock()) return;
        for (auto& file:files_) if (file.second.pid==getpid()) flushLocked(file.first,file.second);
        if (std::getenv("CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS"))
            std::fprintf(stderr,"CABOOSE_CAPABILITY_CACHE hits=%llu misses=%llu scopes=%zu writes=%llu write_bytes=%llu write_us=%llu contended=%llu\n",
                         (unsigned long long)hits_,(unsigned long long)misses_,identities_.size(),(unsigned long long)writes_,
                         (unsigned long long)writeBytes_,(unsigned long long)writeMicros_,(unsigned long long)contended_);
        closeAll();
    }
    static constexpr size_t kMaxEntries=8192, kMaxKeyBytes=4096, kMaxValueBytes=4096;
    static constexpr size_t kMaxScopes=64, kMaxFileBytes=8u<<20, kMaxPendingBytes=256u<<10;
    template<class... Parts> static std::string key(uint32_t query,const Parts&... parts) {
        std::string out; append(&out,query); (append(&out,parts),...); return out;
    }
    static uint64_t digest(const std::string& value) {
        uint64_t hash=0xcbf29ce484222325ull;
        for (unsigned char byte:value) hash=(hash^byte)*0x100000001b3ull;
        return hash;
    }
    // Called only after receiving the identity from this connected physical device.
    // The filename hash is an index, never proof: the full identity must match on read.
    void identify(uint64_t physical,std::string identity,const std::string& directory,uint64_t expectedEpoch=0) {
        if (!physical || identity.empty() || identity.size()>kMaxKeyBytes) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (expectedEpoch && expectedEpoch!=epoch_) return;
        if (!identities_.count(physical) && identities_.size()>=kMaxScopes) return;
        if (connection_.empty() || connection_.size()+identity.size()>kMaxKeyBytes) return;
        identity=connection_+identity;
        identities_[physical]=identity;
        if (directory.empty() || files_.count(identity) || files_.size()>=kMaxScopes) return;
        char suffix[40]; std::snprintf(suffix,sizeof(suffix),"/formats-%016llx.bin",(unsigned long long)digest(identity));
        Scope& scope=files_[identity];
        scope.path=directory+suffix;
        loadLocked(identity,scope);
    }
    // A replacement executor cannot inherit physical handle associations, even when
    // its handles reuse the old numeric values. Persistent files stay identity scoped.
    void connection(const void* bytes,size_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        ++epoch_; identities_.clear(); closeAll(); entries_.clear();
        connection_.assign(static_cast<const char*>(bytes),count<=256 ? count : 0);
    }
    void reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        ++epoch_; identities_.clear(); closeAll(); entries_.clear(); connection_.clear();
    }
    template<class T> bool lookup(const std::string& input,T* out) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (disabled()) { ++misses_; return false; }
        auto it=entries_.find(normalize(input).second);
        if (it==entries_.end() || it->second.size()!=sizeof(T)) { ++misses_; return false; }
        ++hits_;
        std::memcpy(out,it->second.data(),sizeof(T)); return true;
    }
    template<class T> void store(const std::string& input,const T& value) {
        if (disabled()) return;
        if (input.size()>kMaxKeyBytes || sizeof(T)>kMaxValueBytes) return;
        std::lock_guard<std::mutex> lock(mutex_);
        auto scoped=normalize(input);
        const bool known=entries_.count(scoped.second);
        if (!known && entries_.size()>=kMaxEntries) return;
        std::string bytes(reinterpret_cast<const char*>(&value),sizeof(T));
        entries_[scoped.second]=bytes;
        if (!known && !scoped.first.empty()) appendLocked(scoped.first,scoped.second,bytes);
    }
    uint64_t epoch() { std::lock_guard<std::mutex> lock(mutex_); return epoch_; }
    size_t size() { std::lock_guard<std::mutex> lock(mutex_); return entries_.size(); }
    uint64_t writes() { std::lock_guard<std::mutex> lock(mutex_); return writes_; }
    uint64_t writeBytes() { std::lock_guard<std::mutex> lock(mutex_); return writeBytes_; }
private:
    // One append-only record log per device scope. Descriptors are opened once per
    // scope and process; each new answer appends one record under an exclusive lock.
    struct Scope {
        std::string path,name;
        int dir=-1,lock=-1,data=-1;
        pid_t pid=0;
        dev_t device=0; ino_t inode=0;
        uint64_t end=0;   // bytes of the data file known to be header + valid records
        bool synced=false;
        std::string pending; // records not yet appended because the lock was busy
        uint64_t pendingRecords=0;
    };
    static bool disabled() { const char* value=std::getenv("CABOOSE_CAPABILITY_CACHE_DISABLE"); return value && !std::strcmp(value,"1"); }
    template<class T> static void append(std::string* out,const T& value) {
        out->append(reinterpret_cast<const char*>(&value),sizeof(T));
    }
    static std::string header(const std::string& identity) {
        std::string out("CBCQ\2\0\0\0",8);
        append(&out,uint32_t(identity.size())); out+=identity; return out;
    }
    static std::string scopePrefix(const std::string& identity) {
        std::string out(1,'P'); append(&out,uint32_t(identity.size())); out+=identity; return out;
    }
    std::pair<std::string,std::string> normalize(const std::string& input) const {
        if (input.size()<12) return {"",std::string(1,'L')+input};
        uint64_t physical=0; std::memcpy(&physical,input.data()+4,8);
        auto scope=identities_.find(physical);
        if (scope==identities_.end()) return {"",std::string(1,'L')+input};
        std::string out=scopePrefix(scope->second);
        out.append(input.data(),4); out.append(input.data()+12,input.size()-12);
        return {scope->second,out};
    }
    static bool regularOwned(int fd,struct stat* info) {
        return !fstat(fd,info) && S_ISREG(info->st_mode) && info->st_nlink==1 &&
               info->st_uid==geteuid() && !(info->st_mode&0077) && info->st_size>=0 &&
               size_t(info->st_size)<=kMaxFileBytes;
    }
    static int directory(const std::string& path,std::string* name) {
        auto slash=path.rfind('/');
        if (path.empty() || path[0]!='/' || slash==std::string::npos) return -1;
        *name=path.substr(slash+1);
        int fd=open("/",O_RDONLY|O_CLOEXEC|O_DIRECTORY);
        size_t at=1;
        while (fd>=0 && at<=slash) {
            auto end=path.find('/',at); if (end==std::string::npos || end>slash) end=slash;
            std::string part=path.substr(at,end-at); at=end+1;
            if (part.empty() || part=="." || part=="..") { close(fd); return -1; }
            int next=openat(fd,part.c_str(),O_RDONLY|O_CLOEXEC|O_DIRECTORY|O_NOFOLLOW);
            close(fd); fd=next;
            if (fd<0) return -1;
            struct stat info{};
            if (fstat(fd,&info) || (info.st_uid!=0 && info.st_uid!=geteuid()) ||
                ((info.st_mode&0022) && !(info.st_mode&S_ISVTX))) { close(fd); return -1; }
        }
        struct stat info{};
        if (fd>=0 && (fstat(fd,&info) || info.st_uid!=geteuid() || (info.st_mode&0077))) {
            close(fd); return -1;
        }
        return fd;
    }
    static void closeScope(Scope& scope) {
        for (int* fd:{&scope.data,&scope.lock,&scope.dir}) if (*fd>=0) { close(*fd); *fd=-1; }
        scope.synced=false; scope.end=0; scope.pid=0;
    }
    void closeAll() { for (auto& file:files_) closeScope(file.second); files_.clear(); }
    // Opens the scope's directory and lock once per process. A forked child shares its
    // parent's lock description, so it reopens its own before taking the lock.
    static bool openScope(Scope& scope) {
        if (scope.pid==getpid() && scope.dir>=0 && scope.lock>=0) return true;
        closeScope(scope);
        scope.dir=directory(scope.path,&scope.name);
        if (scope.dir<0) return false;
        scope.lock=openat(scope.dir,(scope.name+".lock").c_str(),O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK,0600);
        struct stat info{};
        if (scope.lock<0 || !regularOwned(scope.lock,&info) || info.st_size) { closeScope(scope); return false; }
        scope.pid=getpid();
        return true;
    }
    // Reads `[from, size)` and decodes records in order. Each record is checksummed and
    // must carry the full scope prefix; decoding stops at the first damaged or partial
    // record, so a torn tail costs only the records after it. Returns the valid end.
    uint64_t decodeLocked(int fd,const std::string& identity,uint64_t from,uint64_t size) {
        std::string bytes(size_t(size-from),'\0'); size_t got=0;
        while (got<bytes.size()) {
            ssize_t n=pread(fd,bytes.data()+got,bytes.size()-got,off_t(from+got));
            if (n<=0) break;
            got+=size_t(n);
        }
        bytes.resize(got);
        const std::string scope=scopePrefix(identity);
        size_t at=0;
        while (bytes.size()-at>=16) {
            uint32_t keys=0,values=0; uint64_t checksum=0;
            std::memcpy(&keys,bytes.data()+at,4); std::memcpy(&values,bytes.data()+at+4,4);
            std::memcpy(&checksum,bytes.data()+at+8,8);
            if (keys<=scope.size() || keys>kMaxKeyBytes*2+16 || !values || values>kMaxValueBytes ||
                size_t(keys)+values>bytes.size()-at-16) break;
            std::string key=bytes.substr(at+16,keys),value=bytes.substr(at+16+keys,values);
            if (digest(key+value)!=checksum || key.compare(0,scope.size(),scope)) break;
            if (entries_.size()<kMaxEntries || entries_.count(key)) entries_.emplace(std::move(key),std::move(value));
            at+=16+size_t(keys)+values;
        }
        return from+at;
    }
    void loadLocked(const std::string& identity,Scope& scope) {
        if (!openScope(scope)) return;
        // Non-blocking locks: another writer is a cache miss, never startup latency.
        if (flock(scope.lock,LOCK_SH|LOCK_NB)) return;
        int fd=openat(scope.dir,scope.name.c_str(),O_RDWR|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
        struct stat info{};
        if (fd>=0 && regularOwned(fd,&info)) {
            const auto prefix=header(identity);
            std::string head(prefix.size(),'\0');
            if (size_t(info.st_size)>=prefix.size() &&
                pread(fd,head.data(),head.size(),0)==ssize_t(head.size()) && head==prefix) {
                scope.end=decodeLocked(fd,identity,prefix.size(),uint64_t(info.st_size));
                scope.synced=scope.end==uint64_t(info.st_size);
            }
            scope.data=fd; scope.device=info.st_dev; scope.inode=info.st_ino; fd=-1;
        }
        if (fd>=0) close(fd);
        flock(scope.lock,LOCK_UN);
    }
    // With the exclusive lock held: make `scope.data` the file at the scope's name and
    // `scope.end` its valid length, adopting records other processes appended and
    // cutting a torn tail or a file of another format back to what is valid.
    bool syncLocked(const std::string& identity,Scope& scope) {
        const auto prefix=header(identity);
        struct stat named{};
        if (fstatat(scope.dir,scope.name.c_str(),&named,AT_SYMLINK_NOFOLLOW)) {
            if (errno!=ENOENT) return false;
            if (scope.data>=0) { close(scope.data); scope.data=-1; }
            int fd=openat(scope.dir,scope.name.c_str(),O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
            if (fd<0) return false;
            struct stat info{};
            if (!regularOwned(fd,&info) || pwrite(fd,prefix.data(),prefix.size(),0)!=ssize_t(prefix.size())) {
                close(fd); (void)unlinkat(scope.dir,scope.name.c_str(),0); return false;
            }
            scope.data=fd; scope.device=info.st_dev; scope.inode=info.st_ino;
            scope.end=prefix.size(); scope.synced=true;
            return true;
        }
        if (scope.data<0 || named.st_dev!=scope.device || named.st_ino!=scope.inode) {
            if (scope.data>=0) { close(scope.data); scope.data=-1; }
            scope.synced=false;
            int fd=openat(scope.dir,scope.name.c_str(),O_RDWR|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
            if (fd<0) return false;
            scope.data=fd;
        }
        struct stat info{};
        if (!regularOwned(scope.data,&info)) return false;
        scope.device=info.st_dev; scope.inode=info.st_ino;
        const uint64_t size=uint64_t(info.st_size);
        if (scope.synced && size==scope.end) return true;
        if (!scope.synced || size<scope.end) {
            std::string head(prefix.size(),'\0');
            if (size<prefix.size() || pread(scope.data,head.data(),head.size(),0)!=ssize_t(head.size()) || head!=prefix) {
                // Another format or a damaged header: restart the log in place.
                if (ftruncate(scope.data,0) || pwrite(scope.data,prefix.data(),prefix.size(),0)!=ssize_t(prefix.size()))
                    return false;
                scope.end=prefix.size(); scope.synced=true;
                return true;
            }
            scope.end=prefix.size();
        }
        scope.end=decodeLocked(scope.data,identity,scope.end,size);
        if (scope.end<size && ftruncate(scope.data,off_t(scope.end))) return false;
        scope.synced=true;
        return true;
    }
    void appendLocked(const std::string& identity,const std::string& key,const std::string& value) {
        const auto started=std::chrono::steady_clock::now();
        struct Timing { uint64_t& micros; std::chrono::steady_clock::time_point start;
            ~Timing() { micros+=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count(); }
        } timing{writeMicros_,started};
        auto file=files_.find(identity); if (file==files_.end()) return;
        Scope& scope=file->second;
        std::string record;
        append(&record,uint32_t(key.size())); append(&record,uint32_t(value.size()));
        append(&record,digest(key+value)); record+=key; record+=value;
        // Records wait, within a fixed budget, while another process holds the lock and
        // go out with the next append; past the budget they are only process-local.
        if (scope.pending.size()+record.size()<=kMaxPendingBytes) { scope.pending+=record; ++scope.pendingRecords; }
        flushLocked(identity,scope);
    }
    void flushLocked(const std::string& identity,Scope& scope) {
        if (scope.pending.empty() || !openScope(scope)) return;
        if (flock(scope.lock,LOCK_EX|LOCK_NB)) { ++contended_; return; }
        if (!syncLocked(identity,scope)) {
            scope.synced=false;
        } else if (scope.end+scope.pending.size()>kMaxFileBytes) {
            scope.pending.clear(); scope.pendingRecords=0;
        } else if (pwrite(scope.data,scope.pending.data(),scope.pending.size(),off_t(scope.end))==ssize_t(scope.pending.size())) {
            // Cache durability is optional, so there is no fsync. A crash or failed
            // write leaves at most a partial final record, which readers ignore and
            // the next writer cuts away.
            scope.end+=scope.pending.size(); writes_+=scope.pendingRecords; writeBytes_+=scope.pending.size();
            scope.pending.clear(); scope.pendingRecords=0;
        } else {
            scope.synced=false;
            (void)ftruncate(scope.data,off_t(scope.end));
        }
        flock(scope.lock,LOCK_UN);
    }
    uint64_t epoch_=1,hits_=0,misses_=0,writes_=0,writeBytes_=0,writeMicros_=0,contended_=0;
    std::string connection_;
    std::mutex mutex_;
    std::unordered_map<uint64_t,std::string> identities_;
    std::unordered_map<std::string,Scope> files_;
    std::unordered_map<std::string,std::string> entries_;
};
inline StaticQueryCache staticQueryCache;
} // namespace caboose::memory
