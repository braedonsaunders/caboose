// SPDX-License-Identifier: MIT
// test_upload_cache_vectors VECTORS_JSON: the guest's upload cache wire forms, hashed with
// Mesa's BLAKE3, against the vectors the phone's decoder and store are tested with.
#include "upload_cache.h"

extern "C" {
#include "blake3.h"
}

#include <cassert>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

using namespace caboose::upload_cache;

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
    for (size_t i = 0; i < out.size(); ++i) out[i] = uint8_t(std::stoi(hex.substr(2 * i, 2), nullptr, 16));
    return out;
}

std::vector<uint8_t> pattern(unsigned shift) {
    std::vector<uint8_t> bytes(kPieceBytes);
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = uint8_t((i + shift) % 251);
    return bytes;
}

std::vector<uint8_t> blake3(const uint8_t* data, size_t size) {
    std::vector<uint8_t> key(32);
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, data, size);
    blake3_hasher_finalize(&hasher, key.data(), key.size());
    return key;
}

void prefixHash(const uint8_t* piece, Prefix* prefix) {
    const auto key = blake3(piece, kPieceBytes);
    std::memcpy(prefix->data(), key.data(), kPrefixBytes);
}

}  // namespace

int main(int argc, char** argv) {
    assert(argc == 2);
    std::ifstream file(argv[1]);
    std::stringstream buffer;
    buffer << file.rdbuf();
    const std::string json = buffer.str();
    const auto a = pattern(0), b = pattern(7);
    assert(blake3(a.data(), a.size()) == fromHex(vectorHex(json, "blake3_piece_a")));
    assert(blake3(b.data(), b.size()) == fromHex(vectorHex(json, "blake3_piece_b")));

    uint8_t request[kInventoryPacketBytes];
    encodeInventoryRequest(request);
    assert(std::vector<uint8_t>(request, request + sizeof(request)) == fromHex(vectorHex(json, "inventory_packet")));

    uint32_t count = 0, allowance = 0;
    const auto empty = fromHex(vectorHex(json, "inventory_reply_empty_no_allowance"));
    assert(empty.size() == 8 && inventoryHead(empty.data(), &count, &allowance) && count == 0 && allowance == 0);
    const auto reply = fromHex(vectorHex(json, "inventory_reply_a_b_allowance_65536"));
    assert(inventoryHead(reply.data(), &count, &allowance) && count == 2 && allowance == 65536);
    assert(reply.size() == 8 + 2 * kPrefixBytes);
    const auto tooMany = fromHex(vectorHex(json, "inventory_reply_too_many"));
    uint32_t badCount = 0, badAllowance = 0;
    assert(!inventoryHead(tooMany.data(), &badCount, &badAllowance));

    // The process holds the reply's prefixes; a and b are named, a third piece is stored.
    Inventory inventory;
    assert(inventory.ensure([&](std::vector<uint8_t>* prefixes, uint32_t* granted) {
        prefixes->assign(reply.begin() + 8, reply.end());
        *granted = allowance;
        return true;
    }) == Inventory::State::loaded);
    StreamKnown stream;
    Prefix prefix;
    assert(plan(inventory, stream, a.data(), prefixHash, &prefix) == stored);
    assert(plan(inventory, stream, b.data(), prefixHash, &prefix) == stored);
    const auto c = pattern(13);
    assert(plan(inventory, stream, c.data(), prefixHash, &prefix) == store);

    std::vector<uint8_t> wire;
    auto write = [&](const void* data, size_t size) {
        const auto* bytes = static_cast<const uint8_t*>(data);
        wire.insert(wire.end(), bytes, bytes + size);
    };
    prefixHash(a.data(), &prefix);
    writePiece(stored, a.data(), prefix, inventory, stream, write, prefixHash);
    assert(wire == fromHex(vectorHex(json, "piece_stored_a")));
    wire.clear();
    StreamKnown fresh;
    writePiece(store, a.data(), prefix, inventory, fresh, write, prefixHash);
    assert(wire == fromHex(vectorHex(json, "piece_store_a")));
    assert(fresh.contains(inventory, prefix));
    return 0;
}
