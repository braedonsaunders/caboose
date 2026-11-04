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
#include <time.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace caboose::memory {
// Exact, immutable physical-device answers. Unsupported query chains bypass this cache
// at the call site. A persistent scope includes backend, device/driver and guest build
// identity; without a verified scope answers remain process-local.
class StaticQueryCache {
public:
    ~StaticQueryCache() { finish(); }
    // One last nonblocking attempt for records a busy lock held back, at exit. Exit never
    // waits: a mutex another thread (or a forking parent) holds skips it.
    void finish() {
        std::unique_lock<std::mutex> lock(mutex_,std::try_to_lock);
        if (!lock.owns_lock()) return;
        for (auto& file:files_) if (file.second.pid==getpid()) flushLocked(file.first,file.second);
        if (std::getenv("CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS"))
            std::fprintf(stderr,"CABOOSE_CAPABILITY_CACHE hits=%llu misses=%llu scopes=%zu writes=%llu write_bytes=%llu write_us=%llu contended=%llu"
                         " claims=%llu joined=%llu join_us=%llu discovery_us=%llu\n",
                         (unsigned long long)hits_,(unsigned long long)misses_,identities_.size(),(unsigned long long)writes_,
                         (unsigned long long)writeBytes_,(unsigned long long)writeMicros_,(unsigned long long)contended_,
                         (unsigned long long)claims_,(unsigned long long)joined_,(unsigned long long)(joinNanos_/1000),
                         (unsigned long long)(firstLookup_ ? (lastLookup_-firstLookup_)/1000 : 0));
        closeAll();
    }
    static constexpr size_t kMaxEntries=8192, kMaxKeyBytes=4096, kMaxValueBytes=65536;
    // The scope of answers no physical device is asked for (the executor's instance version),
    // identified as a physical device is: a key value no handle takes.
    static constexpr uint64_t kInstanceScope=1;
    // Where a process keeps its scopes' logs: `capabilities/` beside the executor socket it
    // was given, otherwise the user's cache directory. Empty when it cannot be made.
    static std::string defaultDirectory() {
        const char* socket=std::getenv("CABOOSE_GFXSTREAM_SOCKET");
        std::string directory;
        if (socket && socket[0]=='/' && std::strrchr(socket,'/')!=socket) {
            directory=std::string(socket,size_t(std::strrchr(socket,'/')-socket))+"/capabilities";
        } else {
            const char* cache=std::getenv("XDG_CACHE_HOME");
            const char* home=std::getenv("HOME");
            directory=cache && *cache=='/' ? std::string(cache)
                : home && *home=='/' ? std::string(home)+"/.cache" : std::string();
            if (!directory.empty()) { mkdir(directory.c_str(),0700); directory+="/caboose-gpu"; }
        }
        if (!directory.empty() && mkdir(directory.c_str(),0700)!=0 && errno!=EEXIST) directory.clear();
        return directory;
    }
    static constexpr size_t kMaxScopes=64, kMaxFileBytes=8u<<20, kMaxPendingBytes=256u<<10;
    // How long a claim holds other processes back from asking the same question: far
    // longer than one round trip, short enough that a claimant that died costs little.
    static constexpr uint64_t kClaimNanos=2000000000ull, kJoinPollNanos=500000ull;
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
    // `name` begins the log's file name: "formats" logs are kept as the next sessions' history
    // (warmup/README.md); others end with their session.
    void identify(uint64_t physical,std::string identity,const std::string& directory,uint64_t expectedEpoch=0,
                  const char* name="formats") {
        if (!physical || identity.empty() || identity.size()>kMaxKeyBytes) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (expectedEpoch && expectedEpoch!=epoch_) return;
        if (!identities_.count(physical) && identities_.size()>=kMaxScopes) return;
        if (connection_.empty() || connection_.size()+identity.size()>kMaxKeyBytes) return;
        identity=connection_+identity;
        identities_[physical]=identity;
        if (directory.empty() || files_.count(identity) || files_.size()>=kMaxScopes) return;
        char suffix[64]; std::snprintf(suffix,sizeof(suffix),"/%.16s-%016llx.bin",name,(unsigned long long)digest(identity));
        Scope& scope=files_[identity];
        scope.path=directory+suffix;
        loadLocked(identity,scope);
    }
    // Whether `physical` has a scope on the current connection.
    bool identified(uint64_t physical) {
        std::lock_guard<std::mutex> lock(mutex_);
        return identities_.count(physical)!=0;
    }
    // A replacement executor cannot inherit physical handle associations, even when
    // its handles reuse the old numeric values. Persistent files stay identity scoped.
    void connection(const void* bytes,size_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        ++epoch_; identities_.clear(); closeAll(); entries_.clear(); waits_.clear();
        connection_.assign(static_cast<const char*>(bytes),count<=256 ? count : 0);
    }
    void reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        ++epoch_; identities_.clear(); closeAll(); entries_.clear(); waits_.clear(); connection_.clear();
    }
    // A miss in a persistent scope first takes the answers other processes appended since.
    // When another process has claimed the same question and its answer is still due, the
    // lookup joins it: it waits for that answer (at most until the claim lapses) instead
    // of asking again. Otherwise it claims the question and the caller asks it, then
    // `store`s the answer. A process never waits for questions it did not ask.
    template<class T> bool lookup(const std::string& input,T* out) {
        std::string bytes;
        if (!lookupValue(input,sizeof(T),&bytes)) return false;
        std::memcpy(out,bytes.data(),sizeof(T)); return true;
    }
    // An answer of any size (a structure chain or a list), for `storeBytes`.
    bool lookupBytes(const std::string& input,std::string* out) { return lookupValue(input,0,out); }
    template<class T> void store(const std::string& input,const T& value) {
        storeBytes(input,std::string(reinterpret_cast<const char*>(&value),sizeof(T)));
    }
    // Stores the answer to the question this thread last looked up, only while the connection
    // it was asked on is still current: an answer read as lost (its executor left) and stored
    // after another thread connected a new executor would otherwise be the new one's.
    void storeBytes(const std::string& input,const std::string& bytes) {
        if (disabled()) return;
        if (input.size()>kMaxKeyBytes || bytes.empty() || bytes.size()>kMaxValueBytes) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (lookupEpoch()!=~0ull && lookupEpoch()!=epoch_) return;
        auto scoped=normalize(input);
        const bool known=entries_.count(scoped.second);
        if (!known && entries_.size()>=kMaxEntries) return;
        entries_[scoped.second]=bytes; waits_.erase(scoped.second);
        if (!known && !scoped.first.empty()) appendLocked(scoped.first,scoped.second,bytes);
    }
    uint64_t epoch() { std::lock_guard<std::mutex> lock(mutex_); return epoch_; }
private:
    // `expected` is the answer's size, or 0 for any.
    // The connection epoch of this thread's last lookup.
    static uint64_t& lookupEpoch() { static thread_local uint64_t epoch=~0ull; return epoch; }
    bool lookupValue(const std::string& input,size_t expected,std::string* out) {
        std::unique_lock<std::mutex> lock(mutex_);
        lookupEpoch()=epoch_;
        if (disabled()) { ++misses_; return false; }
        auto scoped=normalize(input);
        auto found=[&]() {
            auto it=entries_.find(scoped.second);
            if (it==entries_.end() || (expected && it->second.size()!=expected)) return false;
            *out=it->second; return true;
        };
        if (!scoped.first.empty()) lastLookup_=monotonic(), firstLookup_=firstLookup_ ? firstLookup_ : lastLookup_;
        if (found()) { ++hits_; return true; }
        if (scoped.first.empty() || !files_.count(scoped.first)) { ++misses_; return false; }
        const uint64_t epoch=epoch_, started=monotonic();
        for (;;) {
            auto file=files_.find(scoped.first);
            if (epoch!=epoch_ || file==files_.end()) { ++misses_; return false; }
            adoptLocked(scoped.first,file->second);
            if (found()) {
                const uint64_t waited=monotonic()-started;
                if (waited>kJoinPollNanos/2) { ++joined_; joinNanos_+=waited; }
                ++hits_; return true;
            }
            auto wait=waits_.find(scoped.second);
            if (wait==waits_.end() || wait->second.token==token() || wait->second.deadline<=monotonic()) break;
            lock.unlock();
            struct timespec pause{0,long(kJoinPollNanos)}; nanosleep(&pause,nullptr);
            lock.lock();
        }
        joinNanos_+=monotonic()-started;
        claimLocked(scoped.first,scoped.second);
        ++misses_; return false;
    }
public:
    size_t size() { std::lock_guard<std::mutex> lock(mutex_); return entries_.size(); }
    uint64_t writes() { std::lock_guard<std::mutex> lock(mutex_); return writes_; }
    uint64_t writeBytes() { std::lock_guard<std::mutex> lock(mutex_); return writeBytes_; }
    uint64_t claims() { std::lock_guard<std::mutex> lock(mutex_); return claims_; }
    uint64_t joined() { std::lock_guard<std::mutex> lock(mutex_); return joined_; }
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
        uint64_t pendingRecords=0,pendingClaims=0;
    };
    // An unanswered claim another process (or thread) made: who, and until when.
    struct Wait { uint64_t deadline=0,token=0; };
    static uint64_t monotonic() {
        // CLOCK_MONOTONIC is one clock for every process of the computer, sandboxed or not.
        struct timespec now{}; clock_gettime(CLOCK_MONOTONIC,&now);
        return uint64_t(now.tv_sec)*1000000000ull+uint64_t(now.tv_nsec);
    }
    // This process's claim token; a forked child is a different claimant.
    uint64_t token() {
        if (tokenPid_!=getpid()) {
            tokenPid_=getpid();
            token_=(uint64_t(uint32_t(tokenPid_))<<32)^monotonic()^uint64_t(reinterpret_cast<uintptr_t>(this));
            if (!token_) token_=1;
        }
        return token_;
    }
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
    // Holders keep the lock for one read or one append, microseconds, so a short retry
    // nearly always gets it; one that stopped while holding it costs at most kLockNanos.
    static constexpr uint64_t kLockNanos=5000000ull;
    static bool lockFile(int fd,int operation) {
        const uint64_t deadline=monotonic()+kLockNanos;
        for (;;) {
            if (!flock(fd,operation|LOCK_NB)) return true;
            if (errno!=EWOULDBLOCK && errno!=EINTR) return false;
            if (monotonic()>=deadline) return false;
            struct timespec pause{0,50000}; nanosleep(&pause,nullptr);
        }
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
            // An answer's key is the scoped key ('P'...); a claim's is the same with 'C'.
            if (digest(key+value)!=checksum || (key[0]!='P' && key[0]!='C') ||
                key.compare(1,scope.size()-1,scope,1,scope.size()-1)) break;
            at+=16+size_t(keys)+values;
            if (key[0]=='C') {
                if (value.size()!=16) break;
                key[0]='P';
                Wait wait; std::memcpy(&wait.deadline,value.data(),8); std::memcpy(&wait.token,value.data()+8,8);
                if (!entries_.count(key) && (waits_.size()<kMaxEntries || waits_.count(key))) waits_[key]=wait;
                continue;
            }
            waits_.erase(key);
            if (entries_.size()<kMaxEntries || entries_.count(key)) entries_.emplace(std::move(key),std::move(value));
        }
        return from+at;
    }
    // With the shared lock: take records other processes appended since this process last
    // looked. A reader never cuts the file; a damaged tail waits for the next writer.
    void adoptLocked(const std::string& identity,Scope& scope) {
        if (!openScope(scope) || !lockFile(scope.lock,LOCK_SH)) return;
        const auto prefix=header(identity);
        if (scope.data<0) {
            int fd=openat(scope.dir,scope.name.c_str(),O_RDWR|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
            struct stat opened{};
            if (fd>=0 && !regularOwned(fd,&opened)) { close(fd); fd=-1; }
            if (fd>=0) { scope.data=fd; scope.device=opened.st_dev; scope.inode=opened.st_ino; scope.synced=false; }
        }
        struct stat named{},info{};
        if (scope.data>=0 && !fstatat(scope.dir,scope.name.c_str(),&named,AT_SYMLINK_NOFOLLOW) &&
            named.st_dev==scope.device && named.st_ino==scope.inode && regularOwned(scope.data,&info)) {
            const uint64_t size=uint64_t(info.st_size);
            if (!scope.synced || size<scope.end) {
                std::string head(prefix.size(),'\0');
                if (size>=prefix.size() && pread(scope.data,head.data(),head.size(),0)==ssize_t(head.size()) && head==prefix) {
                    scope.end=decodeLocked(scope.data,identity,prefix.size(),size);
                    scope.synced=scope.end==size;
                }
            } else if (size>scope.end) {
                scope.end=decodeLocked(scope.data,identity,scope.end,size);
                scope.synced=scope.end==size;
            }
        }
        flock(scope.lock,LOCK_UN);
    }
    void claimLocked(const std::string& identity,const std::string& key) {
        auto file=files_.find(identity); if (file==files_.end()) return;
        Scope& scope=file->second;
        std::string claim=key; claim[0]='C';
        std::string value; append(&value,monotonic()+kClaimNanos); append(&value,token());
        std::string record;
        append(&record,uint32_t(claim.size())); append(&record,uint32_t(value.size()));
        append(&record,digest(claim+value)); record+=claim; record+=value;
        if (scope.pending.size()+record.size()>kMaxPendingBytes) return;
        scope.pending+=record; ++scope.pendingClaims;
        flushLocked(identity,scope);
    }
    void loadLocked(const std::string& identity,Scope& scope) {
        if (!openScope(scope)) return;
        // Bounded locks: a writer that keeps the lock is a cache miss, never startup latency.
        if (!lockFile(scope.lock,LOCK_SH)) return;
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
        if (!lockFile(scope.lock,LOCK_EX)) { ++contended_; return; }
        if (!syncLocked(identity,scope)) {
            scope.synced=false;
        } else if (scope.end+scope.pending.size()>kMaxFileBytes) {
            scope.pending.clear(); scope.pendingRecords=0; scope.pendingClaims=0;
        } else if (pwrite(scope.data,scope.pending.data(),scope.pending.size(),off_t(scope.end))==ssize_t(scope.pending.size())) {
            // Cache durability is optional, so there is no fsync. A crash or failed
            // write leaves at most a partial final record, which readers ignore and
            // the next writer cuts away.
            scope.end+=scope.pending.size(); writes_+=scope.pendingRecords; writeBytes_+=scope.pending.size();
            claims_+=scope.pendingClaims;
            scope.pending.clear(); scope.pendingRecords=0; scope.pendingClaims=0;
        } else {
            scope.synced=false;
            (void)ftruncate(scope.data,off_t(scope.end));
        }
        flock(scope.lock,LOCK_UN);
    }
    uint64_t epoch_=1,hits_=0,misses_=0,writes_=0,writeBytes_=0,writeMicros_=0,contended_=0;
    uint64_t claims_=0,joined_=0,joinNanos_=0,firstLookup_=0,lastLookup_=0,token_=0;
    pid_t tokenPid_=0;
    std::string connection_;
    std::mutex mutex_;
    std::unordered_map<uint64_t,std::string> identities_;
    std::unordered_map<std::string,Scope> files_;
    std::unordered_map<std::string,std::string> entries_;
    std::unordered_map<std::string,Wait> waits_;
};
// Never destroyed (a process's exit runs static destructors while its other threads may still
// be inside the driver); its held-back records get their last attempt at exit.
inline StaticQueryCache& staticQueryCache = *[] {
    auto* cache = new StaticQueryCache;
    std::atexit([] { staticQueryCache.finish(); });
    return cache;
}();
} // namespace caboose::memory
