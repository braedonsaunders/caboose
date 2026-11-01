// SPDX-License-Identifier: MIT
// The guest's upload cache decisions, its wire forms and the flush plumbing they use. The
// hash here is a stand-in; upload-cache/test_upload_cache_vectors.cpp checks BLAKE3 and the
// byte-exact forms against the phone's vectors.
#include "flush_packet.h"
#include "upload_cache.h"

#include <cassert>
#include <string>
#include <vector>

using namespace caboose;
using namespace caboose::upload_cache;

namespace {

std::string hex(const uint8_t* bytes, size_t size) {
    static const char digits[] = "0123456789abcdef";
    std::string out;
    for (size_t i = 0; i < size; ++i) {
        out += digits[bytes[i] >> 4];
        out += digits[bytes[i] & 15];
    }
    return out;
}

// Stand-in hash: the piece's first 16 bytes, so tests choose keys by content.
void standIn(const uint8_t* piece, Prefix* prefix) { std::memcpy(prefix->data(), piece, kPrefixBytes); }

std::vector<uint8_t> piece(uint8_t first) {
    std::vector<uint8_t> bytes(kPieceBytes, 0);
    bytes[0] = first;
    bytes[kPieceBytes - 1] = 1;
    return bytes;
}

Prefix prefixOf(const std::vector<uint8_t>& bytes) {
    Prefix prefix;
    standIn(bytes.data(), &prefix);
    return prefix;
}

}  // namespace

int main() {
    // Wire forms.
    uint8_t request[kInventoryPacketBytes];
    encodeInventoryRequest(request);
    assert(hex(request, sizeof(request)) == "11fe4243100000000100000000000000");
    uint8_t header[kPieceHeaderBytes];
    encodePieceHeader(header, store);
    assert(hex(header, sizeof(header)) == "001000000000008001000000");
    encodePieceHeader(header, stored);
    assert(hex(header, sizeof(header)) == "001000000000008002000000");
    assert(pieceDataBytes(store) == 12 + 4096 && pieceDataBytes(stored) == 12 + 16);
    uint32_t count = 0, allowance = 0;
    const uint8_t good[8] = {2, 0, 0, 0, 0, 0, 1, 0};
    assert(inventoryHead(good, &count, &allowance) && count == 2 && allowance == 65536);
    const uint8_t tooMany[8] = {1, 0, 4, 0, 0, 0, 0, 0};
    assert(!inventoryHead(tooMany, &count, &allowance));
    const uint8_t tooMuchAllowance[8] = {0, 0, 0, 0, 1, 0, 1, 0};
    assert(!inventoryHead(tooMuchAllowance, &count, &allowance));

    // Pieces are counted from the range's offset, in whichever chunk they fall.
    assert(firstPiece(64, 64) == 64);
    assert(firstPiece(64, 64 + 4096) == 64 + 4096);
    assert(firstPiece(64, 100) == 64 + 4096);
    std::vector<uint8_t> zero(kPieceBytes, 0);
    assert(zeroPiece(zero.data()) && !zeroPiece(piece(0).data()));

    // The inventory: unavailable when the phone cannot answer, charged to the budget, and
    // forgotten by a new executor.
    memory::Budget budget{1024};
    {
        Inventory unanswered{budget};
        assert(unanswered.ensure([](std::vector<uint8_t>*, uint32_t*) { return false; }) ==
               Inventory::State::unavailable);
        assert(!unanswered.takeAllowance());
    }
    const auto a = piece(0xa), b = piece(0xb), c = piece(0xc), d = piece(0xd);
    Inventory inventory{budget};
    unsigned loads = 0;
    auto loadA = [&](std::vector<uint8_t>* prefixes, uint32_t* granted) {
        ++loads;
        const Prefix key = prefixOf(a);
        prefixes->assign(key.begin(), key.end());
        *granted = 2;
        return true;
    };
    assert(inventory.ensure(loadA) == Inventory::State::loaded && loads == 1);
    assert(inventory.ensure(loadA) == Inventory::State::loaded && loads == 1);
    assert(budget.used() == sizeof(Prefix));
    assert(inventory.contains(prefixOf(a)) && !inventory.contains(prefixOf(b)));
    assert(inventory.offers());
    {
        Inventory empty{budget};
        assert(!empty.offers());
        assert(empty.ensure([](std::vector<uint8_t>* p, uint32_t* g) { p->clear(); *g = 0; return true; }) ==
               Inventory::State::loaded);
        assert(!empty.offers());
    }

    // Kind per piece: zero pieces never; held ones by prefix; others stored while the
    // allowance lasts; a piece stored on this stream is named on it, not on another.
    StreamKnown stream, other;
    Prefix prefix;
    assert(plan(inventory, stream, zero.data(), true, standIn, &prefix) == literal);
    assert(plan(inventory, stream, a.data(), true, standIn, &prefix) == stored && prefix == prefixOf(a));
    assert(plan(inventory, stream, b.data(), true, standIn, &prefix) == store && prefix == prefixOf(b));
    std::vector<uint8_t> wire;
    auto write = [&](const void* data, size_t size) {
        const auto* bytes = static_cast<const uint8_t*>(data);
        wire.insert(wire.end(), bytes, bytes + size);
    };
    writePiece(store, b.data(), prefix, inventory, stream, write, standIn);
    assert(wire.size() == pieceDataBytes(store));
    assert(hex(wire.data(), kPieceHeaderBytes) == "001000000000008001000000");
    assert(std::memcmp(wire.data() + kPieceHeaderBytes, b.data(), kPieceBytes) == 0);
    assert(stream.contains(inventory, prefixOf(b)) && !other.contains(inventory, prefixOf(b)));
    assert(plan(inventory, stream, b.data(), true, standIn, &prefix) == stored);
    assert(plan(inventory, other, b.data(), true, standIn, &prefix) == store);
    assert(plan(inventory, stream, c.data(), true, standIn, &prefix) == literal);  // allowance spent
    assert(counts().stored == 2 && counts().namedInventory == 1 && counts().namedStream == 1 &&
           counts().literal == 2);
    wire.clear();
    writePiece(stored, a.data(), prefixOf(a), inventory, stream, write, standIn);
    assert(wire.size() == pieceDataBytes(stored));
    assert(std::memcmp(wire.data() + kPieceHeaderBytes, prefixOf(a).data(), kPrefixBytes) == 0);

    // Only staging memory is stored: buffers copied from, never ones read per draw.
    {
        Inventory fresh{budget};
        StreamKnown none;
        assert(fresh.ensure([](std::vector<uint8_t>* p, uint32_t* g) { p->clear(); *g = 4; return true; }) ==
               Inventory::State::loaded);
        assert(plan(fresh, none, d.data(), false, standIn, &prefix) == literal);
        assert(plan(fresh, none, d.data(), true, standIn, &prefix) == store);
    }
    assert(staging(0x1) && staging(0x1 | 0x2));       // TRANSFER_SRC, with TRANSFER_DST
    assert(!staging(0x2) && !staging(0));             // never copied from, or no buffer
    assert(!staging(0x1 | 0x80) && !staging(0x1 | 0x10) && !staging(0x1 | 0x40) &&
           !staging(0x1 | 0x20) && !staging(0x1 | 0x100));  // vertex, uniform, index, storage, indirect

    // The key that becomes known is the hash of the bytes written, not of the planned ones.
    StreamKnown raced;
    wire.clear();
    writePiece(store, d.data(), prefixOf(c), inventory, raced, write, standIn);
    assert(raced.contains(inventory, prefixOf(d)) && !raced.contains(inventory, prefixOf(c)));

    // A new executor forgets the inventory, its allowance and every stream's pieces, and
    // releases the budget; the next flush asks again.
    inventory.reset();
    assert(!inventory.contains(prefixOf(a)) && !inventory.takeAllowance());
    assert(!stream.contains(inventory, prefixOf(b)) && stream.size(inventory) == 0);
    assert(budget.used() == 0);
    assert(inventory.ensure(loadA) == Inventory::State::loaded && loads == 2);

    // An executor change during the request discards the answer.
    inventory.reset();
    assert(inventory.ensure([&](std::vector<uint8_t>* prefixes, uint32_t* granted) {
        inventory.reset();
        return loadA(prefixes, granted);
    }) == Inventory::State::unknown);
    assert(inventory.ensure(loadA) == Inventory::State::loaded);

    // Malformed or unaffordable inventories leave the cache off.
    for (auto load : std::vector<bool (*)(std::vector<uint8_t>*, uint32_t*)>{
             [](std::vector<uint8_t>* p, uint32_t* g) { p->assign(15, 1); *g = 0; return true; },
             [](std::vector<uint8_t>* p, uint32_t* g) { p->clear(); *g = kMaxAllowance + 1; return true; },
             [](std::vector<uint8_t>* p, uint32_t* g) { p->assign(65 * kPrefixBytes, 1); *g = 1; return true; }}) {
        Inventory refused{budget};
        assert(refused.ensure(load) == Inventory::State::unavailable);
        assert(!refused.takeAllowance());
    }
    inventory.reset();
    assert(!inventory.contains(prefixOf(a)) && budget.used() == 0);

    // Chunks of a cacheable range start at whole pieces from its offset.
    {
        constexpr size_t bytes = 300 * 1024;
        std::shared_ptr<uint8_t> mapping(new uint8_t[bytes], std::default_delete<uint8_t[]>());
        std::vector<std::pair<uint64_t, uint64_t>> chunks;
        assert(memory::transact(false, 1, [&](uint32_t, memory::Range& r) {
            r.base = mapping.get(); r.lifetime = mapping; r.mapEnd = r.allocation = bytes;
            r.offset = 64; r.size = bytes - 64 - 128; r.atom = 64; return true;
        }, [&](uint32_t, uint64_t offset, uint64_t size, uint8_t*) {
            chunks.emplace_back(offset, size); return 0;
        }, memory::processBudget, kPieceBytes) == 0);
        uint64_t next = 64;
        for (size_t i = 0; i < chunks.size(); ++i) {
            assert(chunks[i].first == next && (chunks[i].first - 64) % kPieceBytes == 0);
            assert(chunks[i].second <= memory::payloadBytes);
            if (i + 1 < chunks.size()) assert(chunks[i].second % kPieceBytes == 0);
            next += chunks[i].second;
        }
        assert(next == bytes - 128);
        // An atom the granule does not divide keeps chunks at atoms.
        chunks.clear();
        assert(memory::transact(false, 1, [&](uint32_t, memory::Range& r) {
            r.base = mapping.get(); r.lifetime = mapping; r.mapEnd = r.allocation = bytes;
            r.offset = 0; r.size = 3 * 6000; r.atom = 6000; return true;
        }, [&](uint32_t, uint64_t offset, uint64_t size, uint8_t*) {
            chunks.emplace_back(offset, size); return 0;
        }, memory::processBudget, kPieceBytes) == 0);
        assert(chunks.size() == 1 && chunks[0].second == 3 * 6000);
    }

    // A piece takes a fragment of its own, charged at its piece form.
    {
        std::vector<memory::FlushFragment> sent;
        uint64_t wireBytes = 0;
        memory::FlushPacket packet{
            [&](const memory::FlushFragment* parts, size_t n, uint64_t bytes) {
                sent.assign(parts, parts + n); wireBytes = bytes; return 0;
            }, [](int& result) { result = 0; return true; }, [] { assert(false); }};
        assert(packet.push(0, 0, 64) == 0);
        assert(packet.pushPiece(0, 4096, store, prefixOf(b)) == 0);
        assert(packet.pushPiece(1, 0, stored, prefixOf(a)) == 0);
        assert(packet.finish() == 0);
        assert(sent.size() == 3 && sent[0].kind == literal);
        assert(sent[1].kind == store && sent[1].offset == 4096 && sent[1].size == kPieceBytes);
        assert(sent[2].kind == stored && sent[2].prefix == prefixOf(a) && sent[2].range == 1);
        assert(wireBytes == 20 + (40 + 64) + (32 + 12 + 4096) + (32 + 12 + 16));
        // Pieces fill packets to the same ceiling.
        unsigned packets = 0;
        memory::FlushPacket many{
            [&](const memory::FlushFragment*, size_t n, uint64_t bytes) {
                assert(n <= memory::flushFragmentCapacity && bytes <= memory::flushPacketByteLimit);
                ++packets; return 0;
            }, [](int& result) { result = 0; return true; }, [] { assert(false); }};
        for (unsigned i = 0; i < 1000; ++i) assert(many.pushPiece(0, uint64_t(i) * kPieceBytes, store, prefix) == 0);
        assert(many.finish() == 0 && packets == 1000 / 64 + 1);
        memory::FlushPacket refused{
            [](const memory::FlushFragment*, size_t, uint64_t) { return 0; },
            [](int& result) { result = 0; return true; }, [] {}};
        assert(refused.pushPiece(0, 0, literal, prefix) == -4);
    }
    assert(memory::processBudget.used() == 0);
    return 0;
}
