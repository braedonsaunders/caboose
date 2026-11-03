// SPDX-License-Identifier: MIT
#pragma once
#include <cstdint>
#include <cerrno>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
        if (std::getenv("CABOOSE_CAPABILITY_CACHE_DIAGNOSTICS"))
            std::fprintf(stderr,"CABOOSE_CAPABILITY_CACHE hits=%llu misses=%llu scopes=%zu\n",
                         (unsigned long long)hits_,(unsigned long long)misses_,identities_.size());
    }
    static constexpr size_t kMaxEntries=8192, kMaxKeyBytes=4096, kMaxValueBytes=4096;
    static constexpr size_t kMaxScopes=64, kMaxFileBytes=8u<<20;
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
        files_[identity]=directory+suffix;
        loadLocked(identity,files_[identity]);
    }
    // A replacement executor cannot inherit physical handle associations, even when
    // its handles reuse the old numeric values. Persistent files stay identity scoped.
    void connection(const void* bytes,size_t count) {
        std::lock_guard<std::mutex> lock(mutex_);
        ++epoch_; identities_.clear(); files_.clear(); entries_.clear();
        connection_.assign(static_cast<const char*>(bytes),count<=256 ? count : 0);
    }
    void reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        ++epoch_; identities_.clear(); files_.clear(); entries_.clear(); connection_.clear();
    }
    template<class T> bool lookup(const std::string& input,T* out) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it=entries_.find(normalize(input).second);
        if (it==entries_.end() || it->second.size()!=sizeof(T)) { ++misses_; return false; }
        ++hits_;
        std::memcpy(out,it->second.data(),sizeof(T)); return true;
    }
    template<class T> void store(const std::string& input,const T& value) {
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
private:
    template<class T> static void append(std::string* out,const T& value) {
        out->append(reinterpret_cast<const char*>(&value),sizeof(T));
    }
    static std::string header(const std::string& identity) {
        std::string out("CBCQ\1\0\0\0",8);
        append(&out,uint32_t(identity.size())); out+=identity; return out;
    }
    std::pair<std::string,std::string> normalize(const std::string& input) const {
        if (input.size()<12) return {"",std::string(1,'L')+input};
        uint64_t physical=0; std::memcpy(&physical,input.data()+4,8);
        auto scope=identities_.find(physical);
        if (scope==identities_.end()) return {"",std::string(1,'L')+input};
        std::string out(1,'P'); append(&out,uint32_t(scope->second.size())); out+=scope->second;
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
    void loadLocked(const std::string& identity,const std::string& path) {
        std::string name; int dir=directory(path,&name); if (dir<0) return;
        int lock=openat(dir,(name+".lock").c_str(),O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK,0600);
        struct stat lockInfo{};
        if (lock<0 || !regularOwned(lock,&lockInfo) || lockInfo.st_size || flock(lock,LOCK_SH|LOCK_NB)) {
            if (lock>=0) close(lock);
            close(dir); return;
        }
        int fd=openat(dir,name.c_str(),O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
        close(dir);
        if (fd<0) { close(lock); return; }
        struct stat info{};
        // Non-blocking locks: another writer is a cache miss, never startup latency.
        if (!regularOwned(fd,&info)) { close(fd); close(lock); return; }
        std::string bytes(size_t(info.st_size),'\0'); size_t got=0;
        while (got<bytes.size()) {
            ssize_t n=pread(fd,bytes.data()+got,bytes.size()-got,off_t(got));
            if (n<=0) break;
            got+=size_t(n);
        }
        close(fd); close(lock);
        auto prefix=header(identity);
        if (got!=bytes.size() || bytes.size()<prefix.size() || bytes.compare(0,prefix.size(),prefix)) return;
        // Validate the entire snapshot before publishing any answers; malformed data is
        // never partially authoritative. A writer holds an exclusive lock over a record.
        std::vector<std::pair<std::string,std::string>> decoded;
        size_t at=prefix.size();
        while (at<bytes.size()) {
            if (bytes.size()-at<16 || decoded.size()>=kMaxEntries) return;
            uint32_t keys=0,values=0; uint64_t checksum=0;
            std::memcpy(&keys,bytes.data()+at,4); std::memcpy(&values,bytes.data()+at+4,4);
            std::memcpy(&checksum,bytes.data()+at+8,8); at+=16;
            if (!keys || keys>kMaxKeyBytes*2+16 || !values || values>kMaxValueBytes ||
                size_t(keys)+values>bytes.size()-at) return;
            std::string key=bytes.substr(at,keys),value=bytes.substr(at+keys,values);
            if (digest(key+value)!=checksum) return;
            std::string scope(1,'P'); append(&scope,uint32_t(identity.size())); scope+=identity;
            if (key.compare(0,scope.size(),scope)) return;
            decoded.emplace_back(std::move(key),std::move(value)); at+=size_t(keys)+values;
        }
        for (auto& entry:decoded) {
            if (entries_.size()>=kMaxEntries && !entries_.count(entry.first)) break;
            entries_.insert_or_assign(std::move(entry.first),std::move(entry.second));
        }
    }
    void appendLocked(const std::string& identity,const std::string& key,const std::string& value) {
        auto path=files_.find(identity); if (path==files_.end()) return;
        std::string name; int dir=directory(path->second,&name); if (dir<0) return;
        int lock=openat(dir,(name+".lock").c_str(),O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK,0600);
        struct stat info{};
        if (lock<0 || !regularOwned(lock,&info) || info.st_size || flock(lock,LOCK_EX|LOCK_NB)) {
            if (lock>=0) close(lock);
            close(dir); return;
        }
        std::string bytes=header(identity);
        int old=openat(dir,name.c_str(),O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
        if (old>=0) {
            if (!regularOwned(old,&info)) { close(old); close(lock); close(dir); return; }
            std::string existing(size_t(info.st_size),'\0');
            ssize_t got=pread(old,existing.data(),existing.size(),0); close(old);
            if (got!=ssize_t(existing.size()) || existing.compare(0,bytes.size(),bytes)) {
                close(lock); close(dir); return;
            }
            bytes=std::move(existing);
        } else if (errno!=ENOENT) { close(lock); close(dir); return; }
        append(&bytes,uint32_t(key.size())); append(&bytes,uint32_t(value.size()));
        append(&bytes,digest(key+value)); bytes+=key; bytes+=value;
        if (bytes.size()>kMaxFileBytes) { close(lock); close(dir); return; }
        static std::atomic<uint64_t> serial{0};
        const std::string temp=name+".tmp-"+std::to_string(getpid())+"-"+std::to_string(++serial);
        int fd=openat(dir,temp.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
        if (fd>=0) {
            if (write(fd,bytes.data(),bytes.size())==ssize_t(bytes.size()) && fsync(fd)==0)
                (void)renameat(dir,temp.c_str(),dir,name.c_str());
            close(fd); (void)unlinkat(dir,temp.c_str(),0);
        }
        close(lock); close(dir);
    }
    uint64_t epoch_=1,hits_=0,misses_=0;
    std::string connection_;
    std::mutex mutex_;
    std::unordered_map<uint64_t,std::string> identities_;
    std::unordered_map<std::string,std::string> files_,entries_;
};
inline StaticQueryCache staticQueryCache;
} // namespace caboose::memory
