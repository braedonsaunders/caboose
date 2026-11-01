// Copyright 2026 Caboose contributors. SPDX-License-Identifier: Apache-2.0
// upload_store_test VECTORS_JSON: the phone's persistent upload store and its wire forms,
// against guest/gpu/gfxstream/upload-cache/vectors.json.
#undef NDEBUG
#include "upload_store.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <vector>

using namespace caboose::gpuv2;

namespace {

std::string vectorHex(const std::string& json, const char* name) {
    const std::string marker = std::string("\"") + name + "\": \"";
    const size_t start = json.find(marker);
    assert(start != std::string::npos);
    const size_t from = start + marker.size();
    return json.substr(from, json.find('"', from) - from);
}

std::vector<uint8_t> fromHex(const std::string& hex) {
    std::vector<uint8_t> out(hex.size() / 2);
    for (size_t i = 0; i < out.size(); ++i) out[i] = static_cast<uint8_t>(std::stoi(hex.substr(2 * i, 2), nullptr, 16));
    return out;
}

std::string toHex(const uint8_t* bytes, size_t size) {
    static const char digits[] = "0123456789abcdef";
    std::string hex;
    for (size_t i = 0; i < size; ++i) { hex += digits[bytes[i] >> 4]; hex += digits[bytes[i] & 15]; }
    return hex;
}

std::vector<uint8_t> piece(uint32_t seed) {
    std::vector<uint8_t> bytes(kUploadPieceBytes);
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<uint8_t>((i + seed) % 251);
    return bytes;
}

uint64_t le64(const std::vector<uint8_t>& bytes) {
    uint64_t value = 0;
    for (int i = 7; i >= 0; --i) value = value << 8 | bytes[i];
    return value;
}

// A pack written as the store writes one: the key table, then the slots.
void writePack(const std::string& path, const std::vector<std::pair<UploadKey, std::vector<uint8_t>>>& slots, time_t mtime) {
    const int fd = ::open(path.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0);
    assert(ftruncate(fd, off_t(kUploadPackSlots) * kUploadKeyBytes) == 0);
    for (size_t i = 0; i < slots.size(); ++i) {
        assert(pwrite(fd, slots[i].second.data(), kUploadPieceBytes,
                      off_t(kUploadPackSlots) * kUploadKeyBytes + off_t(i) * kUploadPieceBytes) == off_t(kUploadPieceBytes));
        assert(pwrite(fd, slots[i].first.bytes, kUploadKeyBytes, off_t(i) * kUploadKeyBytes) == off_t(kUploadKeyBytes));
    }
    close(fd);
    struct timeval times[2] = {{mtime, 0}, {mtime, 0}};
    assert(utimes(path.c_str(), times) == 0);
}

bool holds(const std::vector<UploadPrefix>& prefixes, const UploadPrefix& prefix) {
    for (const auto& p : prefixes) if (p == prefix) return true;
    return false;
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc == 2);
    std::ifstream file(argv[1]);
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string json = buffer.str();
    assert(!json.empty());

    // Keys are BLAKE3-256 of the 4096 bytes, as the guest computes them.
    const auto a = piece(0), b = piece(7);
    const UploadKey keyA = uploadKeyOf(a.data()), keyB = uploadKeyOf(b.data());
    assert(toHex(keyA.bytes, kUploadKeyBytes) == vectorHex(json, "blake3_piece_a"));
    assert(toHex(keyB.bytes, kUploadKeyBytes) == vectorHex(json, "blake3_piece_b"));

    // UPLOAD_INVENTORY and its replies.
    const auto packet = fromHex(vectorHex(json, "inventory_packet"));
    assert(parseUploadInventoryPacket(packet.data(), packet.size()));
    for (size_t i = 8; i < packet.size(); ++i) {
        auto bad = packet;
        bad[i] ^= 1;
        assert(!parseUploadInventoryPacket(bad.data(), bad.size()));
    }
    assert(!parseUploadInventoryPacket(packet.data(), packet.size() - 1));
    assert(encodeUploadInventoryReply({}, 0) == fromHex(vectorHex(json, "inventory_reply_empty_no_allowance")));
    assert(encodeUploadInventoryReply({keyA.prefix(), keyB.prefix()}, 65536) ==
           fromHex(vectorHex(json, "inventory_reply_a_b_allowance_65536")));
    // Never more than 65536 pieces of allowance, nor more than 262144 prefixes.
    assert(encodeUploadInventoryReply({}, 1u << 20) == encodeUploadInventoryReply({}, 65536));
    {
        std::vector<UploadPrefix> many(kUploadInventoryMaxKeys + 1);
        const auto reply = encodeUploadInventoryReply(many, 0);
        assert(reply.size() == 8 + size_t(kUploadInventoryMaxKeys) * kUploadPrefixBytes);
        assert(reply[0] == 0 && reply[1] == 0 && reply[2] == 4 && reply[3] == 0);
    }

    // The piece forms, after each fragment's u64 length.
    const auto storeA = fromHex(vectorHex(json, "piece_store_a"));
    const auto storedA = fromHex(vectorHex(json, "piece_stored_a"));
    const auto literalA = fromHex(vectorHex(json, "literal_a"));
    assert(uploadPieceSize(le64(storeA), storeA.data() + 8, storeA.size() - 8) == int64_t(storeA.size() - 8));
    assert(std::memcmp(storeA.data() + 12, a.data(), a.size()) == 0);
    assert(uploadPieceSize(le64(storedA), storedA.data() + 8, storedA.size() - 8) == int64_t(storedA.size() - 8));
    assert(uploadPieceSize(le64(storedA), storedA.data() + 8, 3) == 0);  // the kind is not there yet
    assert(uploadPieceSize(le64(literalA), literalA.data() + 8, literalA.size() - 8) == -1);  // not a piece
    for (const char* name : {"short_piece", "other_length_bits", "unknown_kind", "kind_0"}) {
        const auto bad = fromHex(vectorHex(json, name));
        assert(uploadPieceSize(le64(bad), bad.data() + 8, bad.size() - 8) == -1);
    }
    const auto unresolvable = fromHex(vectorHex(json, "unresolvable_prefix"));
    assert(uploadPieceSize(le64(unresolvable), unresolvable.data() + 8, unresolvable.size() - 8) == 20);

    char pattern[] = "/tmp/upload-store-test.XXXXXX";
    const std::string root = mkdtemp(pattern);
    const std::string dir = root + "/uploads";
    uint8_t out[kUploadPieceBytes];
    {
        // A stored piece resolves at once, from memory, then from its pack.
        auto store = UploadStore::open(dir);
        assert(store && store->inventory().empty() && store->allowance() > 0);
        assert(!store->resolve(keyA.prefix().bytes, out));
        store->store(a.data());
        assert(store->resolve(keyA.prefix().bytes, out) && std::memcmp(out, a.data(), sizeof(out)) == 0);
        store->drain();
        std::memset(out, 0, sizeof(out));
        assert(store->resolve(keyA.prefix().bytes, out) && std::memcmp(out, a.data(), sizeof(out)) == 0);
        // A second store of the same piece, as from another stream of the process, is kept once.
        store->store(a.data());
        store->store(b.data());
        store->drain();
        const auto s = store->stats();
        assert(s.pieces == 2 && s.stored == 2 && s.duplicates == 1 && s.packs == 1);
        const auto inventory = store->inventory();
        assert(inventory.size() == 2 && holds(inventory, keyA.prefix()) && holds(inventory, keyB.prefix()));
        assert(!store->resolve(unresolvable.data() + 12, out));
    }
    {
        // Reopened, the index comes back from the pack's keys; new pieces join the same pack.
        auto store = UploadStore::open(dir);
        assert(store->inventory().size() == 2);
        assert(store->resolve(keyB.prefix().bytes, out) && std::memcmp(out, b.data(), sizeof(out)) == 0);
        const auto c = piece(13);
        store->store(c.data());
        store->drain();
        assert(store->stats().packs == 1 && store->inventory().size() == 3);
    }
    {
        // A slot that no longer matches its key does not resolve.
        const int fd = ::open((dir + "/00000000.pack").c_str(), O_RDWR);
        assert(fd >= 0);
        const uint8_t junk = 0xEE;
        assert(pwrite(fd, &junk, 1, off_t(kUploadPackSlots) * kUploadKeyBytes) == 1);  // slot 0: piece a
        close(fd);
        auto store = UploadStore::open(dir);
        assert(!store->resolve(keyA.prefix().bytes, out));
        assert(store->resolve(keyB.prefix().bytes, out));
    }
    {
        // Two keys with one prefix: neither is listed, neither resolves.
        const std::string other = root + "/ambiguous";
        assert(mkdir(other.c_str(), 0700) == 0);
        UploadKey twin = keyB;
        std::memcpy(twin.bytes, keyA.bytes, kUploadPrefixBytes);
        writePack(other + "/00000000.pack", {{keyA, a}, {twin, b}, {keyB, b}}, 1000);
        auto store = UploadStore::open(other);
        const auto inventory = store->inventory();
        assert(inventory.size() == 1 && holds(inventory, keyB.prefix()));
        assert(!store->resolve(keyA.prefix().bytes, out));
        // A piece a guest stores under that prefix is still resolvable for the run.
        store->store(a.data());
        store->drain();
        assert(store->resolve(keyA.prefix().bytes, out) && std::memcmp(out, a.data(), sizeof(out)) == 0);
    }
    {
        // The budget applies at open, dropping whole least recently used packs, and bounds
        // the allowance.
        const std::string other = root + "/budget";
        assert(mkdir(other.c_str(), 0700) == 0);
        const auto c = piece(13), d = piece(21);
        writePack(other + "/00000001.pack", {{keyA, a}, {keyB, b}}, 1000);
        writePack(other + "/00000002.pack", {{uploadKeyOf(c.data()), c}}, 2000);
        writePack(other + "/0000000x.pack", {}, 3000);  // not a pack name: left alone
        const uint64_t cost = kUploadPieceBytes + kUploadKeyBytes;
        auto store = UploadStore::open(other, UploadStoreLimits{2 * cost, 100});
        assert(store->stats().droppedPacksAtOpen == 1 && store->stats().packs == 1);
        const auto inventory = store->inventory();
        assert(inventory.size() == 1 && holds(inventory, uploadKeyOf(c.data()).prefix()));
        assert(store->allowance() == 1);
        store->store(d.data());
        assert(store->allowance() == 0);
        store.reset();
        struct stat st {};
        assert(stat((other + "/00000001.pack").c_str(), &st) != 0);
        assert(stat((other + "/0000000x.pack").c_str(), &st) == 0);
    }
    {
        // A pending budget of one piece: the decoder waits for the writer, nothing is lost.
        const std::string other = root + "/pending";
        auto store = UploadStore::open(other, UploadStoreLimits{1ull << 30, 100, kUploadPieceBytes});
        for (uint32_t seed = 0; seed < 200; ++seed) store->store(piece(seed).data());
        for (uint32_t seed = 0; seed < 200; ++seed) {
            const auto p = piece(seed);
            assert(store->resolve(uploadKeyOf(p.data()).prefix().bytes, out) && std::memcmp(out, p.data(), sizeof(out)) == 0);
        }
        store.reset();
        assert(UploadStore::open(other)->inventory().size() == 200);
    }
    {
        // The decoder hooks, through the store of the current root.
        storeUploadPiece(a.data());  // no root: nothing kept, nothing resolves
        assert(!resolveUploadPiece(keyA.prefix().bytes, out));
        assert(setUploadStoreRoot(root + "/hooks") == 0);
        storeUploadPiece(a.data());
        assert(resolveUploadPiece(keyA.prefix().bytes, out) && std::memcmp(out, a.data(), sizeof(out)) == 0);
        assert(setUploadStoreRoot(root + "/third") == 0);
        assert(!resolveUploadPiece(keyA.prefix().bytes, out) && currentUploadStore()->inventory().empty());
        assert(setUploadStoreRoot(root + "/hooks") == 0);
        assert(resolveUploadPiece(keyA.prefix().bytes, out));
        assert(setUploadStoreRoot({}) == 0 && !currentUploadStore());
    }
    std::system(("rm -rf '" + root + "'").c_str());
    std::puts("upload_store_test: ok");
    return 0;
}
